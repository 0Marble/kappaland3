const std = @import("std");
const StringStore = @import("StringStore.zig");
const Options = @import("Options");
const Queue = @import("queue.zig").Queue;
const Log = @import("Log.zig");

pub const EntityRef = u64;
pub const SystemRef = u64;
pub const ComponentRef = u64;

pub const Error = error{
    ComponentAlreadyDefined,
    SystemOrderLoop,
    SystemAlreadyDefined,
    InvalidEntity,
    InvalidComponent,
    DeadEntity,
    ComponentTypecheckError,
} || std.mem.Allocator.Error;

const DecodedSystemRef = union(enum) {
    const OFFSET = std.math.maxInt(@typeInfo(@FieldType(@This(), "reserved")).@"enum".tag_type) + 1;

    reserved: enum(u8) { invalid = 0, _ },
    index: u64,

    pub fn decode(ref: SystemRef) DecodedSystemRef {
        if (ref < OFFSET) {
            return .{ .reserved = @enumFromInt(ref) };
        } else {
            return .{ .index = ref - OFFSET };
        }
    }
    pub fn encode(self: DecodedSystemRef) SystemRef {
        switch (self) {
            .reserved => |x| return @intFromEnum(x),
            .index => |x| return x + OFFSET,
        }
    }
};

const DecodedComponentRef = union(enum) {
    const DENSE_OFFSET = std.math.maxInt(@typeInfo(@FieldType(@This(), "reserved")).@"enum".tag_type) + 1;
    const SPARSE_OFFSET = (1 << 63) + 1;

    reserved: enum(u8) { invalid = 0, _ },
    dense: u64,
    sparse: u64,

    pub fn decode(ref: ComponentRef) DecodedComponentRef {
        if (ref < DENSE_OFFSET) {
            return .{ .reserved = @enumFromInt(ref) };
        } else if (ref < SPARSE_OFFSET) {
            return .{ .dense = ref - DENSE_OFFSET };
        } else {
            return .{ .sparse = ref - SPARSE_OFFSET };
        }
    }

    pub fn encode(self: DecodedComponentRef) ComponentRef {
        switch (self) {
            .reserved => |x| return @intFromEnum(x),
            .dense => |x| return x + DENSE_OFFSET,
            .sparse => |x| return x + SPARSE_OFFSET,
        }
    }
};

const DecodedEntityRef = struct {
    const INDEX_SIZE = 56;
    const GEN_SIZE = @typeInfo(EntityRef).int.bits - INDEX_SIZE;
    const GenInt = std.meta.Int(.unsigned, GEN_SIZE);
    const IndexInt = std.meta.Int(.unsigned, INDEX_SIZE);
    const GEN_MASK = std.math.boolMask(GenInt, true);

    index: Index,
    generation: GenInt,

    pub const empty: DecodedEntityRef = .{ .index = .none, .generation = 0 };

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("{s}{}@{}", .{ @typeName(EntityRef), self.index, self.generation });
    }

    pub fn from_parts(index: Index, generation: GenInt) DecodedEntityRef {
        return .{
            .index = index,
            .generation = generation,
        };
    }

    pub fn increment_generation(self: DecodedEntityRef) DecodedEntityRef {
        return .{
            .index = self.index,
            .generation = self.generation +% 1,
        };
    }

    pub fn decode(id: EntityRef) DecodedEntityRef {
        const idx = id >> GEN_SIZE;
        return .{
            .generation = @intCast(id & GEN_MASK),
            .index = if (idx < Index.OFFSET) .{ .reserved = @enumFromInt(idx) } else .{ .index = idx - Index.OFFSET },
        };
    }

    pub fn encode(self: DecodedEntityRef) EntityRef {
        const idx = switch (self.index) {
            .reserved => |x| @intFromEnum(x),
            .index => |x| x + Index.OFFSET,
        };
        return @as(EntityRef, @intCast(self.generation)) | (@as(EntityRef, idx) << GEN_SIZE);
    }

    const Index = union(enum) {
        const OFFSET = std.math.maxInt(@typeInfo(@FieldType(@This(), "reserved")).@"enum".tag_type) + 1;
        reserved: enum(u8) { none = 0, _ },
        index: usize,
        const none: Index = .{ .reserved = .none };
    };
};

const ComponentStore = struct {
    const MAX_ALLIGNMENT = std.mem.Alignment.@"64";

    const Info = struct {
        kind: ComponentRef,
        body_type: std.builtin.TypeId,
        body_size: usize,
        body_align: usize,
        name: []const u8,
    };

    info: Info,
    data: std.ArrayListAlignedUnmanaged(u8, MAX_ALLIGNMENT),
    parents: std.ArrayListUnmanaged(EntityRef),
    freelist: std.ArrayListUnmanaged(usize),

    pub fn deinit(self: *ComponentStore, gpa: std.mem.Allocator) void {
        self.data.deinit(gpa);
        self.parents.deinit(gpa);
        self.freelist.deinit(gpa);
    }

    pub fn remove(self: *ComponentStore, ecs: *Ecs, idx: usize) void {
        const ref = self.get(idx);
        ref.parent.* = DecodedEntityRef.empty.encode();
        self.freelist.append(ecs.gpa, idx) catch |err| {
            Log.log(.warn, "Ecs@{*}: failed to add a Component to the freelist: {}", .{ self, err });
        };
    }

    pub fn add(self: *ComponentStore, ecs: *Ecs) Error!Ref {
        if (self.freelist.pop()) |idx| {
            return self.get(idx);
        } else {
            const idx = self.parents.items.len;
            _ = try self.data.addManyAsSlice(ecs.gpa, self.info.body_size);
            _ = try self.parents.addOne(ecs.gpa);
            return self.get(idx);
        }
    }

    const Ref = struct {
        idx: usize,
        parent: *EntityRef,
        data: []u8,
    };

    pub fn count(self: *ComponentStore) usize {
        return self.parents.items.len - self.freelist.items.len;
    }

    pub fn get(self: *ComponentStore, idx: usize) Ref {
        const data = self.data.items[idx * self.info.body_size .. (idx + 1) * self.info.body_size];
        const eid: *EntityRef = &self.parents.items[idx];
        return .{
            .idx = idx,
            .parent = eid,
            .data = data,
        };
    }
};

const SystemStore = struct {
    systems: std.ArrayListUnmanaged(*System),
    edge_freelist: std.ArrayListUnmanaged(*Edge),
    system_freelist: std.ArrayListUnmanaged(SystemRef),
    arena: std.heap.ArenaAllocator,
    names: StringStore,
    stack: std.ArrayListUnmanaged(*System),
    queue: Queue(*System),

    const System = struct {
        id: SystemRef,
        name: []const u8,
        requirements: ?*Edge,
        status: u8,

        data: *anyopaque,
        callback: *const fn (data: *anyopaque, ecs: *Ecs, eid: EntityRef) void,
        query: []const ComponentRef,

        const ALIVE_BIT: u8 = 0x01;
        const VISITED_BIT: u8 = 0x02;
        const COMPLETE_BIT: u8 = 0x04;
        const WORKING_BIT: u8 = 0x08;

        pub inline fn run(self: *System, ecs: *Ecs, eid: EntityRef) void {
            self.callback(self.data, ecs, eid);
        }
    };

    const Edge = struct {
        sys: *System,
        next: ?*Edge,
    };

    pub fn init(gpa: std.mem.Allocator) SystemStore {
        return .{
            .names = .init(gpa),
            .systems = .empty,
            .system_freelist = .empty,
            .edge_freelist = .empty,
            .arena = .init(gpa),
            .stack = .empty,
            .queue = .empty,
        };
    }

    pub fn deinit(self: *SystemStore, gpa: std.mem.Allocator) void {
        self.systems.deinit(gpa);
        self.system_freelist.deinit(gpa);
        self.edge_freelist.deinit(gpa);
        self.stack.deinit(self.arena.allocator());
        self.queue.deinit(self.arena.allocator());
        self.names.deinit(gpa);
        self.arena.deinit();
    }

    pub fn get(self: *SystemStore, ref: SystemRef) *System {
        return self.systems.items[DecodedSystemRef.decode(ref).index];
    }

    pub fn add(self: *SystemStore, name: []const u8, query: []const ComponentRef, ecs: *Ecs) !*System {
        const static_query = try self.arena.allocator().dupe(ComponentRef, query);
        if (self.names.contains(name)) {
            return Error.SystemAlreadyDefined;
        }
        const static_name = try self.names.ensure_stored(ecs.gpa, name);

        if (self.system_freelist.pop()) |old| {
            const sys: *System = self.systems.items[old];
            sys.id = old;
            sys.status = System.ALIVE_BIT;
            sys.name = static_name;
            sys.query = static_query;
            sys.requirements = null;

            return sys;
        } else {
            const sys: *System = try self.arena.allocator().create(System);
            sys.id = (DecodedSystemRef{ .index = self.systems.items.len }).encode();
            sys.status = System.ALIVE_BIT;
            sys.name = static_name;
            sys.query = static_query;
            sys.requirements = null;

            try self.systems.append(ecs.gpa, sys);

            return sys;
        }
    }

    pub fn remove(self: *SystemStore, ecs: *Ecs, ref: SystemRef) void {
        const s = self.get(ref);
        s.status &= ~System.ALIVE_BIT;

        self.system_freelist.append(ecs.gpa, ref) catch |err| {
            Log.log(.warn, "Ecs@{*}: failed to add System to the freelist: {}", .{err});
        };

        var cur = s.requirements;
        while (cur) |n| {
            cur = n.next;
            self.edge_freelist.append(ecs.gpa, n) catch |err| {
                Log.log(.warn, "Ecs@{*}: failed to add Edge to the freelist: {}", .{err});
            };
        }
    }

    pub fn eval_order(self: *SystemStore, before: SystemRef, after: SystemRef) !void {
        const a = self.get(before);
        const b = self.get(after);

        var cur = b.requirements;
        while (cur) |n| {
            cur = n.next;
            if (n.sys == a) return;
        }

        if (try self.reachable(a, b)) return Error.SystemOrderLoop;
        for (self.systems.items) |s| s.status &= ~System.VISITED_BIT;

        const edge = if (self.edge_freelist.pop()) |old| old else try self.arena.allocator().create(Edge);
        edge.sys = a;
        edge.next = b.requirements;
        b.requirements = edge;
    }

    fn reachable(self: *SystemStore, start: *System, target: *System) !bool {
        const alloc = self.arena.allocator();
        self.stack.clearRetainingCapacity();
        start.status |= System.VISITED_BIT;
        try self.stack.append(alloc, start);

        while (self.stack.pop()) |node| {
            if (node == target) return true;
            var edge = node.requirements;
            while (edge) |e| {
                edge = e.next;
                if (e.sys.status & System.VISITED_BIT == 0) {
                    e.sys.status |= System.VISITED_BIT;
                    try self.stack.append(alloc, e.sys);
                }
            }
        }

        return false;
    }

    pub fn eval(self: *SystemStore, ecs: *Ecs) !void {
        const alloc = self.arena.allocator();
        self.queue.clear();

        for (self.systems.items) |sys| {
            if (sys.status & System.ALIVE_BIT == 0) continue;
            if (sys.status & System.COMPLETE_BIT != 0) continue;
            std.debug.assert(sys.status & System.WORKING_BIT == 0);

            try self.queue.push(alloc, sys);
            sys.status |= System.WORKING_BIT;

            while (self.queue.pop()) |cur| {
                var all_complete = true;
                var edge = cur.requirements;
                while (edge) |e| {
                    edge = e.next;
                    const next = e.sys;
                    if (next.status & System.COMPLETE_BIT != 0) {
                        continue;
                    }

                    all_complete = false;
                    if (next.status & System.WORKING_BIT == 0) {
                        next.status |= System.WORKING_BIT;
                        try self.queue.push(alloc, next);
                    }
                }

                if (all_complete) {
                    cur.status |= System.COMPLETE_BIT;
                    cur.status &= ~System.WORKING_BIT;
                    self.force_eval(ecs, cur.id);
                } else {
                    try self.queue.push(alloc, cur);
                }
            }
        }

        for (self.systems.items) |s| s.status &= ~System.COMPLETE_BIT;
    }

    fn force_eval(self: *SystemStore, ecs: *Ecs, ref: SystemRef) void {
        const sys = self.get(ref);
        if (sys.query.len == 0) {
            for (ecs.entities.entities.items) |e| {
                if (e.alive) sys.run(ecs, e.eid);
            }
        } else {
            var start_store: *ComponentStore = undefined;
            var start_count: usize = std.math.maxInt(usize);
            for (sys.query) |kind| {
                const store = switch (DecodedComponentRef.decode(kind)) {
                    .reserved => std.debug.panic("Ecs@{*}: access invalid component", .{self}),
                    .sparse => |x| &ecs.sparse_components.items[x],
                    .dense => |x| &ecs.dense_components.items[x],
                };
                if (store.count() < start_count) {
                    start_count = store.count();
                    start_store = store;
                }
            }

            outer: for (start_store.parents.items) |parent| {
                if (DecodedEntityRef.decode(parent).index == .reserved) continue;
                for (sys.query) |kind| {
                    if (kind == start_store.info.kind) continue;
                    if (!ecs.has_component(parent, kind)) continue :outer;
                }
                sys.run(ecs, parent);
            }
        }
    }
};

const EntityStore = struct {
    entities: std.ArrayListUnmanaged(Entity),
    free_entities: std.ArrayListUnmanaged(EntityRef),
    free_sparse: std.ArrayListUnmanaged(*SparseNode),
    arena: std.heap.ArenaAllocator,

    fn new_sparse(self: *EntityStore) Error!*SparseNode {
        if (self.free_sparse.pop()) |old| return old;
        const new = try self.arena.allocator().create(SparseNode);
        new.* = std.mem.zeroes(SparseNode);
        return new;
    }

    pub fn init(gpa: std.mem.Allocator) EntityStore {
        return .{
            .entities = .empty,
            .free_entities = .empty,
            .free_sparse = .empty,
            .arena = .init(gpa),
        };
    }

    pub fn deinit(self: *EntityStore, gpa: std.mem.Allocator) void {
        for (self.entities.items) |*e| e.deinit(gpa);
        self.free_sparse.deinit(gpa);
        self.entities.deinit(gpa);
        self.free_entities.deinit(gpa);
        self.arena.deinit();
    }
};

const Entity = struct {
    eid: EntityRef,
    components: ComponentSet,
    alive: bool,

    pub fn deinit(self: *Entity, gpa: std.mem.Allocator) void {
        self.components.deinit(gpa);
    }

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try DecodedEntityRef.decode(self.eid).format(writer);
    }
};

const SparseNode = struct {
    kind: ComponentRef,
    idx: usize,
    next: ?*SparseNode,
};

const ComponentSet = struct {
    dense: std.ArrayListUnmanaged(usize),
    sparse: ?*SparseNode,

    pub const empty: ComponentSet = .{ .sparse = null, .dense = .empty };

    pub fn get(self: *ComponentSet, ecs: *Ecs, kind: ComponentRef) ?usize {
        switch (DecodedComponentRef.decode(kind)) {
            .reserved => std.debug.panic("Ecs@{*}: invalid component, should be unreachable", .{ecs}),
            .sparse => {
                var cur = self.sparse;
                while (cur) |node| {
                    cur = node.next;
                    if (node.kind == kind) {
                        return node.idx;
                    }
                }
                return null;
            },
            .dense => |id| {
                if (self.dense.items.len <= id or self.dense.items[id] == 0) {
                    return null;
                } else {
                    return self.dense.items[id] - 1;
                }
            },
        }
    }

    pub fn add(self: *ComponentSet, ecs: *Ecs, kind: ComponentRef, idx: usize) !void {
        switch (DecodedComponentRef.decode(kind)) {
            .reserved => std.debug.panic("Ecs@{*}: invalid component, should be unreachable", .{ecs}),
            .sparse => {
                var cur = self.sparse;
                while (cur) |n| {
                    cur = n.next;
                    if (n.kind == kind) {
                        n.idx = idx;
                        return;
                    }
                }

                const node = try ecs.entities.new_sparse();
                node.kind = kind;
                node.idx = idx;
                node.next = self.sparse;
                self.sparse = node;
            },
            .dense => |id| {
                if (self.dense.items.len <= id) {
                    try self.dense.appendNTimes(
                        ecs.gpa,
                        0,
                        ecs.dense_components.items.len - self.dense.items.len,
                    );
                }
                self.dense.items[id] = idx + 1;
            },
        }
    }

    pub fn remove(self: *ComponentSet, ecs: *Ecs, kind: ComponentRef) ?usize {
        switch (DecodedComponentRef.decode(kind)) {
            .reserved => std.debug.panic("Ecs@{*}: invalid component, should be unreachable", .{ecs}),
            .sparse => {
                var prev: ?*SparseNode = null;
                var cur = self.sparse;
                while (cur) |n| {
                    cur = n.next;
                    if (n.kind == kind) {
                        if (prev) |p| {
                            p.next = cur;
                        } else {
                            self.sparse = cur;
                        }
                        const res = n.idx;

                        n.* = std.mem.zeroes(SparseNode);
                        ecs.entities.free_sparse.append(ecs.gpa, n) catch |err| {
                            Log.log(.warn, "Ecs@{*}: failed to add a SparseNode to the freelist: {}", .{ ecs, err });
                        };
                        return res;
                    }
                    prev = n;
                }
            },
            .dense => |id| {
                if (self.dense.items.len <= id) {
                    return null;
                }
                const res = self.dense.items[id];
                self.dense.items[id] = 0;
                if (res == 0) return null;
                return res - 1;
            },
        }
        return null;
    }

    pub fn clear(self: *ComponentSet, ecs: *Ecs) void {
        for (self.dense.items) |*idx| idx.* = 0;

        var cur = self.sparse;
        while (cur) |node| {
            cur = node.next;
            node.* = std.mem.zeroes(SparseNode);
            ecs.entities.free_sparse.append(ecs.gpa, node) catch |err| {
                Log.log(.warn, "Ecs@{*}: failed to add a SparseNode to the freelist: {}", .{ ecs, err });
            };
        }
    }

    pub fn iter(self: *ComponentSet, ecs: *Ecs) Iter {
        return .{ .stage = .{ .dense = 0 }, .ecs = ecs, .set = self };
    }

    const Iter = struct {
        set: *ComponentSet,
        ecs: *Ecs,
        stage: union(enum) {
            dense: usize,
            sparse: ?*SparseNode,
        },

        const Entry = struct {
            kind: ComponentRef,
            idx: usize,
        };

        pub fn next(self: *Iter) ?Entry {
            switch (self.stage) {
                .dense => |idx| {
                    var i = idx;
                    while (i < self.set.dense.items.len) {
                        if (self.set.dense.items[i] != 0) {
                            self.stage = .{ .dense = i + 1 };
                            return .{
                                .idx = self.set.dense.items[i] - 1,
                                .kind = (DecodedComponentRef{ .dense = i }).encode(),
                            };
                        }
                        i += 1;
                    }
                    self.stage = .{ .sparse = self.set.sparse };
                    return self.next();
                },
                .sparse => |node| {
                    if (node) |n| {
                        self.stage = .{ .sparse = n.next };
                        return .{
                            .kind = n.kind,
                            .idx = n.idx,
                        };
                    } else return null;
                },
            }
        }
    };

    pub fn deinit(self: *ComponentSet, gpa: std.mem.Allocator) void {
        self.dense.deinit(gpa);
    }
};

entities: EntityStore,
dense_components: std.ArrayListUnmanaged(ComponentStore),
sparse_components: std.ArrayListUnmanaged(ComponentStore),
systems: SystemStore,
component_names: StringStore,
gpa: std.mem.Allocator,

const Self = @This();
const Ecs = @This();
pub fn init(gpa: std.mem.Allocator) Self {
    return .{
        .gpa = gpa,
        .component_names = .init(gpa),
        .entities = .init(gpa),
        .systems = .init(gpa),
        .dense_components = .empty,
        .sparse_components = .empty,
    };
}

pub fn deinit(self: *Self) void {
    self.entities.deinit(self.gpa);
    self.systems.deinit(self.gpa);
    self.component_names.deinit(self.gpa);
    for (self.dense_components.items) |*s| s.deinit(self.gpa);
    for (self.sparse_components.items) |*s| s.deinit(self.gpa);
    self.dense_components.deinit(self.gpa);
    self.sparse_components.deinit(self.gpa);
}

pub fn register_component(
    self: *Self,
    name: []const u8,
    comptime Body: type,
    is_sparse: bool,
) Error!ComponentRef {
    if (self.component_names.contains(name)) {
        return Error.ComponentAlreadyDefined;
    }
    const static_name = try self.component_names.ensure_stored(self.gpa, name);
    const info = if (is_sparse) blk: {
        const info = ComponentStore.Info{
            .kind = (DecodedComponentRef{ .sparse = self.sparse_components.items.len }).encode(),
            .name = static_name,
            .body_type = @typeInfo(Body),
            .body_size = @sizeOf(Body),
            .body_align = @alignOf(Body),
        };

        try self.sparse_components.append(self.gpa, .{
            .info = info,
            .data = .empty,
            .freelist = .empty,
            .parents = .empty,
        });
        break :blk info;
    } else blk: {
        const info = ComponentStore.Info{
            .kind = (DecodedComponentRef{ .dense = self.dense_components.items.len }).encode(),
            .name = static_name,
            .body_type = @typeInfo(Body),
            .body_size = @sizeOf(Body),
            .body_align = @alignOf(Body),
        };

        try self.dense_components.append(self.gpa, .{
            .info = info,
            .data = .empty,
            .freelist = .empty,
            .parents = .empty,
        });
        break :blk info;
    };

    if (Options.ecs_logging) {
        Log.log(
            .debug,
            "Ecs@{*}: Registered new component: \"{s}\", kind: {}",
            .{ self, name, DecodedComponentRef.decode(info.kind) },
        );
    }

    return info.kind;
}

pub fn spawn(self: *Self) Error!EntityRef {
    if (self.entities.free_entities.pop()) |old| {
        const eid = DecodedEntityRef.decode(old).increment_generation();
        if (Options.ecs_logging) {
            Log.log(.debug, "Ecs@{*}: reusing old entity {f}", .{ self, eid });
        }
        const idx = eid.index.index;
        const e = &self.entities.entities.items[idx];
        e.eid = eid.encode();
        e.alive = true;
        return e.eid;
    } else {
        const eid = DecodedEntityRef.from_parts(.{ .index = self.entities.entities.items.len }, 0);
        if (Options.ecs_logging) {
            Log.log(.debug, "Ecs@{*}: spawn new entity {f}", .{ self, eid });
        }
        const e = Entity{
            .eid = eid.encode(),
            .components = .empty,
            .alive = true,
        };
        try self.entities.entities.append(self.gpa, e);
        return e.eid;
    }
}

fn get_entity(self: *Self, eid: EntityRef) Error!*Entity {
    const decoded = DecodedEntityRef.decode(eid);
    switch (decoded.index) {
        .reserved => return Error.InvalidEntity,
        .index => |idx| return &self.entities.entities.items[idx],
    }
}
fn get_entity_ensure_alive(self: *Self, eid: EntityRef) Error!*Entity {
    const decoded = DecodedEntityRef.decode(eid);
    switch (decoded.index) {
        .reserved => return Error.InvalidEntity,
        .index => |idx| {
            const e = &self.entities.entities.items[idx];
            if (e.eid != eid or !e.alive) return Error.DeadEntity;
            return e;
        },
    }
}

pub fn kill(self: *Self, eid: EntityRef) void {
    const e = self.get_entity_ensure_alive(eid) catch |err| {
        Log.log(.warn, "Ecs@{*}: tried to kill an invalid entity {d}: {}", .{ self, eid, err });
        return;
    };
    if (Options.ecs_logging) {
        Log.log(.debug, "Ecs@{*}: killing entity {f}", .{ self, e });
    }
    var it = e.components.iter(self);

    while (it.next()) |entry| {
        self.remove_component(e.eid, entry.kind);
    }
    e.components.clear(self);
    e.alive = false;

    self.entities.free_entities.append(self.gpa, eid) catch |err| {
        Log.log(.warn, "Ecs@{*}: failed to add Entity to a freelist: {}", .{ self, err });
    };
}

pub fn add_component(
    self: *Self,
    eid: EntityRef,
    comptime T: type,
    kind: ComponentRef,
    body: T,
) Error!void {
    const e = try self.get_entity_ensure_alive(eid);
    if (Options.ecs_logging) {
        Log.log(.debug, "Ecs@{*}: adding component {} to entity {f}", .{ self, DecodedComponentRef.decode(kind), e });
    }

    const store: *ComponentStore = switch (DecodedComponentRef.decode(kind)) {
        .reserved => return Error.InvalidComponent,
        .sparse => |idx| &self.sparse_components.items[idx],
        .dense => |idx| &self.dense_components.items[idx],
    };

    if (Options.ecs_typecheck) {
        if (@typeInfo(T) != store.info.body_type) {
            Log.log(.err, "Ecs@{*}: failed to typecheck component {}, expected {}, got {}", .{
                self,
                DecodedComponentRef.decode(kind),
                store.info.body_type,
                std.meta.activeTag(@typeInfo(T)),
            });
            return Error.ComponentTypecheckError;
        }
    }

    const ref = try store.add(self);
    @memcpy(ref.data, std.mem.asBytes(&body));
    ref.parent.* = eid;
    try e.components.add(self, kind, ref.idx);
}

pub fn remove_component(self: *Self, eid: EntityRef, kind: ComponentRef) void {
    const e = self.get_entity_ensure_alive(eid) catch |err| {
        Log.log(.warn, "Ecs@{*}: attempted to remove component from an invalid entity {d}: {}", .{ self, eid, err });
        return;
    };
    if (Options.ecs_logging) {
        Log.log(.debug, "Ecs@{*}: removing component {} from entity {f}", .{ self, DecodedComponentRef.decode(kind), e });
    }
    const store = switch (DecodedComponentRef.decode(kind)) {
        .reserved => {
            Log.log(.warn, "Ecs@{*}: attempted to remove an invalid component {}", .{ self, kind });
            return;
        },
        .sparse => |x| &self.sparse_components.items[x],
        .dense => |x| &self.dense_components.items[x],
    };
    const idx = e.components.remove(self, kind) orelse {
        Log.log(.warn, "Ecs@{*}: entity {f} did not have a component {}", .{
            self,
            e,
            DecodedComponentRef.decode(kind),
        });
        return;
    };
    store.remove(self, idx);
}

pub fn has_component(self: *Self, eid: EntityRef, kind: ComponentRef) bool {
    const e = self.get_entity_ensure_alive(eid) catch |err| {
        Log.log(.warn, "Ecs@{*}: accessing an invalid entity {d}: {}", .{ self, eid, err });
        return false;
    };
    if (Options.ecs_logging) {
        Log.log(.debug, "Ecs@{*}: Check if entity {f} has component {}", .{ self, e, DecodedComponentRef.decode(kind) });
    }
    if (DecodedComponentRef.decode(kind) == .reserved) {
        Log.log(.warn, "Ecs@{*}: accessing invalid component {d}", .{ self, kind });
        return false;
    }
    return e.components.get(self, kind) != null;
}

pub fn get_component(self: *Self, eid: EntityRef, comptime T: type, kind: ComponentRef) ?*T {
    const e = self.get_entity_ensure_alive(eid) catch |err| {
        Log.log(.warn, "Ecs@{*}: accessing an invalid entity {d}: {}", .{ self, eid, err });
        return null;
    };
    if (Options.ecs_logging) {
        Log.log(.debug, "Ecs@{*}: get component {} of entity {f}", .{ self, DecodedComponentRef.decode(kind), e });
    }
    const store: *ComponentStore = switch (DecodedComponentRef.decode(kind)) {
        .reserved => {
            Log.log(.warn, "Ecs@{*}: accessing invalid component {d}", .{ self, kind });
            return null;
        },
        .sparse => |idx| &self.sparse_components.items[idx],
        .dense => |idx| &self.dense_components.items[idx],
    };
    if (Options.ecs_typecheck) {
        if (@typeInfo(T) != store.info.body_type) {
            Log.log(.err, "Ecs@{*}: failed to typecheck component {}, expected {}, got {}", .{
                self,
                DecodedComponentRef.decode(kind),
                store.info.body_type,
                std.meta.activeTag(@typeInfo(T)),
            });
            return null;
        }
    }

    const idx = e.components.get(self, kind) orelse return null;
    const ref = store.get(idx);
    std.debug.assert(ref.parent.* == eid);

    return @ptrCast(@alignCast(ref.data));
}

pub fn is_alive(self: *Self, eid: EntityRef) bool {
    _ = self.get_entity_ensure_alive(eid) catch return false;
    return true;
}

const ComponentIter = union(enum) {
    valid: ComponentSet.Iter,
    invalid: void,

    pub inline fn next(self: *ComponentIter) ?ComponentRef {
        if (self.* == .invalid) return null;
        const entry = self.valid.next() orelse return null;
        return entry.kind;
    }
};

pub fn iterate_components(self: *Self, eid: EntityRef) ComponentIter {
    const e = self.get_entity_ensure_alive(eid) catch |err| {
        Log.log(.warn, "Ecs@{*}: accessing an invalid entity {d}: {}", .{ self, eid, err });
        return .invalid;
    };
    return .{ .valid = e.components.iter(self) };
}

pub fn register_system(
    self: *Self,
    comptime Ctx: type,
    name: []const u8,
    query: []const ComponentRef,
    ctx: Ctx,
    callback: *const fn (ctx: Ctx, ecs: *Ecs, eid: EntityRef) void,
) Error!SystemRef {
    const sys = try self.systems.add(name, query, self);
    if (@typeInfo(Ctx) == .pointer) {
        sys.data = @ptrCast(ctx);
        sys.callback = @ptrCast(callback);
    } else {
        const Data = struct { Ctx, @TypeOf(callback) };
        const ptr = try self.systems.arena.allocator().create(Data);
        ptr.* = .{ ctx, callback };
        sys.data = @ptrCast(ptr);
        sys.callback = struct {
            fn do_callback(data: *anyopaque, ecs: *Ecs, eid: EntityRef) void {
                const this: *Data = @ptrCast(@alignCast(data));
                @call(.auto, this[1], .{ this[0], ecs, eid });
            }
        }.do_callback;
    }

    return sys.id;
}

pub fn ensure_eval_order(self: *Self, before: SystemRef, after: SystemRef) Error!void {
    try self.systems.eval_order(before, after);
}

pub fn evaluate(self: *Self) Error!void {
    try self.systems.eval(self);
}

test "Ecs.init" {
    var ecs = Ecs.init(std.testing.allocator);
    defer ecs.deinit();
}

test "Ecs.register_component" {
    var ecs = Ecs.init(std.testing.allocator);
    defer ecs.deinit();

    const pos = try ecs.register_component("Position", @Vector(3, f32), false);
    const vel = try ecs.register_component("Velocity", @Vector(3, f32), false);
    const name = try ecs.register_component("Name", []const u8, false);
    const player_tag = try ecs.register_component("PlayerTag", void, true);
    try std.testing.expectEqual(256, pos);
    try std.testing.expectEqual(257, vel);
    try std.testing.expectEqual(258, name);
    try std.testing.expectEqual((1 << 63) + 1, player_tag);
}

test "Ecs.spawn" {
    var ecs = Ecs.init(std.testing.allocator);
    defer ecs.deinit();

    const Vec3f = @Vector(3, f32);
    const pos = try ecs.register_component("Position", Vec3f, false);
    const vel = try ecs.register_component("Velocity", Vec3f, false);
    const name = try ecs.register_component("Name", []const u8, false);
    const player_tag = try ecs.register_component("PlayerTag", void, true);

    const player = try ecs.spawn();
    try ecs.add_component(player, Vec3f, pos, .{ 0, 10, 0 });
    try ecs.add_component(player, Vec3f, vel, .{ 0, 1, 0 });
    try ecs.add_component(player, []const u8, name, "Player");
    try ecs.add_component(player, void, player_tag, {});

    const zombie = try ecs.spawn();
    try ecs.add_component(zombie, Vec3f, pos, .{ 10, 10, 10 });
    try ecs.add_component(zombie, Vec3f, vel, .{ -10, 0, -10 });
    try ecs.add_component(zombie, []const u8, name, "Zombie");

    const ground = try ecs.spawn();
    try ecs.add_component(ground, Vec3f, pos, .{ 0, 0, 0 });

    try std.testing.expectEqual(.{ 0, 10, 0 }, ecs.get_component(player, Vec3f, pos).?.*);
    try std.testing.expectEqual(.{ 0, 1, 0 }, ecs.get_component(player, Vec3f, vel).?.*);
    try std.testing.expectEqualStrings("Player", ecs.get_component(player, []const u8, name).?.*);
    try std.testing.expect(ecs.has_component(player, player_tag));

    try std.testing.expectEqual(.{ 10, 10, 10 }, ecs.get_component(zombie, Vec3f, pos).?.*);
    try std.testing.expectEqual(.{ -10, 0, -10 }, ecs.get_component(zombie, Vec3f, vel).?.*);
    try std.testing.expectEqualStrings("Zombie", ecs.get_component(zombie, []const u8, name).?.*);
    try std.testing.expect(!ecs.has_component(zombie, player_tag));

    try std.testing.expectEqual(.{ 0, 0, 0 }, ecs.get_component(ground, Vec3f, pos).?.*);
    try std.testing.expectEqual(null, ecs.get_component(ground, Vec3f, vel));
    try std.testing.expectEqual(null, ecs.get_component(ground, []const u8, name));
    try std.testing.expect(!ecs.has_component(ground, player_tag));
}

test "Ecs.kill" {
    var ecs = Ecs.init(std.testing.allocator);
    defer ecs.deinit();

    const Vec3f = @Vector(3, f32);
    const pos = try ecs.register_component("Position", Vec3f, false);
    const vel = try ecs.register_component("Velocity", Vec3f, false);
    const name = try ecs.register_component("Name", []const u8, false);
    const player_tag = try ecs.register_component("PlayerTag", void, true);

    const zombie = try ecs.spawn();
    try ecs.add_component(zombie, Vec3f, pos, .{ 10, 10, 10 });
    try ecs.add_component(zombie, Vec3f, vel, .{ -10, 0, -10 });
    try ecs.add_component(zombie, []const u8, name, "Zombie");
    ecs.kill(zombie);

    const player = try ecs.spawn();
    try std.testing.expectEqual(DecodedEntityRef.decode(zombie).index, DecodedEntityRef.decode(player).index);
    try std.testing.expectEqual(
        DecodedEntityRef.decode(zombie).generation + 1,
        DecodedEntityRef.decode(player).generation,
    );
    try std.testing.expect(ecs.is_alive(player));
    try std.testing.expect(!ecs.is_alive(zombie));

    try ecs.add_component(player, Vec3f, pos, .{ 0, 10, 0 });
    try ecs.add_component(player, Vec3f, vel, .{ 0, 1, 0 });
    try ecs.add_component(player, []const u8, name, "Player");
    try ecs.add_component(player, void, player_tag, {});

    try std.testing.expectEqual(.{ 0, 10, 0 }, ecs.get_component(player, Vec3f, pos).?.*);
    try std.testing.expectEqual(.{ 0, 1, 0 }, ecs.get_component(player, Vec3f, vel).?.*);
    try std.testing.expectEqualStrings("Player", ecs.get_component(player, []const u8, name).?.*);
    try std.testing.expect(ecs.has_component(player, player_tag));
}

test "Ecs.remove_component" {
    var ecs = Ecs.init(std.testing.allocator);
    defer ecs.deinit();

    const Vec3f = @Vector(3, f32);
    const pos = try ecs.register_component("Position", Vec3f, false);
    const vel = try ecs.register_component("Velocity", Vec3f, false);
    const name = try ecs.register_component("Name", []const u8, false);
    const player_tag = try ecs.register_component("PlayerTag", void, true);

    const player = try ecs.spawn();
    try ecs.add_component(player, Vec3f, pos, .{ 0, 10, 0 });
    try ecs.add_component(player, Vec3f, vel, .{ 0, 1, 0 });
    try ecs.add_component(player, []const u8, name, "Player");
    try ecs.add_component(player, void, player_tag, {});
    ecs.remove_component(player, vel);

    try std.testing.expectEqual(.{ 0, 10, 0 }, ecs.get_component(player, Vec3f, pos).?.*);
    try std.testing.expectEqual(null, ecs.get_component(player, Vec3f, vel));
    try std.testing.expectEqualStrings("Player", ecs.get_component(player, []const u8, name).?.*);
    try std.testing.expect(ecs.has_component(player, player_tag));
}

test "Ecs.register_system" {
    var ecs = Ecs.init(std.testing.allocator);
    defer ecs.deinit();

    const Ctx = struct {
        pub fn do_stuff(_: @This(), _: *Ecs, _: EntityRef) void {}
    };
    const system = try ecs.register_system(Ctx, "DummySystem", &.{}, Ctx{}, Ctx.do_stuff);
    _ = system;
}

test "Ecs.ensure_eval_order" {
    var ecs = Ecs.init(std.testing.allocator);
    defer ecs.deinit();

    const Ctx = struct {
        pub fn do_stuff(_: @This(), _: *Ecs, _: EntityRef) void {}
    };
    const a = try ecs.register_system(Ctx, "DummySystem1", &.{}, Ctx{}, Ctx.do_stuff);
    const b = try ecs.register_system(Ctx, "DummySystem2", &.{}, Ctx{}, Ctx.do_stuff);
    try ecs.ensure_eval_order(a, b);
    try std.testing.expectError(Error.SystemOrderLoop, ecs.ensure_eval_order(b, a));
}

test "Ecs.evaluate single" {
    var ecs = Ecs.init(std.testing.allocator);
    defer ecs.deinit();
    const Vec3f = @Vector(3, f32);
    const pos = try ecs.register_component("Position", Vec3f, false);
    const vel = try ecs.register_component("Velocity", Vec3f, false);

    const player = try ecs.spawn();
    try ecs.add_component(player, Vec3f, pos, .{ 0, 0, 0 });
    try ecs.add_component(player, Vec3f, vel, .{ 0, 1, 0 });
    const zombie = try ecs.spawn();
    try ecs.add_component(zombie, Vec3f, pos, .{ 0, 0, -1 });
    try ecs.add_component(zombie, Vec3f, vel, .{ 0, 0, 1 });

    const PhysicsCtx = struct {
        dt: f32,
        pos_component: ComponentRef,
        vel_component: ComponentRef,

        pub fn apply_physics(self: *@This(), e: *Ecs, eid: EntityRef) void {
            const x = e.get_component(eid, Vec3f, self.pos_component).?;
            const v = e.get_component(eid, Vec3f, self.vel_component).?.*;
            x.* = @mulAdd(Vec3f, v, @splat(self.dt), x.*);
        }
    };

    var ctx = PhysicsCtx{ .dt = 1.0, .pos_component = pos, .vel_component = vel };
    const physics = try ecs.register_system(*PhysicsCtx, "Physics", &.{ pos, vel }, &ctx, PhysicsCtx.apply_physics);
    _ = physics;

    try ecs.evaluate();

    try std.testing.expectEqual(.{ 0, 1, 0 }, ecs.get_component(player, Vec3f, pos).?.*);
    try std.testing.expectEqual(.{ 0, 0, 0 }, ecs.get_component(zombie, Vec3f, pos).?.*);
}

test "Ecs.evaluate multiple" {
    var ecs = Ecs.init(std.testing.allocator);
    defer ecs.deinit();
    const Ctx = struct {
        was_ran: bool = false,
        start: usize = 0,
        end: usize = 0,
        envocation_count: usize = 0,

        var step: usize = 0;

        fn system(self: *@This(), _: *Ecs, _: EntityRef) void {
            if (!self.was_ran) {
                self.was_ran = true;
                self.start = step;
            }
            self.envocation_count += 1;
            self.end = step;
            step += 1;
        }
    };

    const entity_count = 10;
    for (0..entity_count) |_| _ = try ecs.spawn();

    var a = Ctx{};
    var b = Ctx{};
    var c = Ctx{};

    const c_sys = try ecs.register_system(*Ctx, "C", &.{}, &c, Ctx.system);
    const a_sys = try ecs.register_system(*Ctx, "A", &.{}, &a, Ctx.system);
    const b_sys = try ecs.register_system(*Ctx, "B", &.{}, &b, Ctx.system);

    try ecs.ensure_eval_order(a_sys, c_sys);
    try ecs.ensure_eval_order(b_sys, c_sys);
    try ecs.evaluate();

    try std.testing.expect(a.was_ran);
    try std.testing.expect(b.was_ran);
    try std.testing.expect(c.was_ran);

    try std.testing.expectEqual(entity_count, a.envocation_count);
    try std.testing.expectEqual(entity_count, b.envocation_count);
    try std.testing.expectEqual(entity_count, c.envocation_count);

    try std.testing.expect(a.end < c.start);
    try std.testing.expect(b.end < c.start);
}
