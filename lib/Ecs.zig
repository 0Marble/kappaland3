const std = @import("std");
const StringStore = @import("StringStore.zig");
const Options = @import("Options");
const Queue = @import("queue.zig").Queue;
const Log = @import("Log.zig");

pub const EntityRef = u64;
pub const SystemRef = u64;
pub const ComponentRef = u64;
pub const EventRef = u64;

pub const Error = error{
    NameAlreadyDefined,
    SystemOrderLoop,
    InvalidEntity,
    InvalidComponent,
    DeadEntity,
    ComponentTypecheckError,
    InvalidEvent,
} || std.mem.Allocator.Error;

const DecodedRef = union(enum) {
    reserved: enum(u8) { none = 0, _ },

    entity: u64,
    dense_component: u64,
    sparse_component: u64,
    system: u64,
    event: u64,

    const OFFSET = std.math.maxInt(u64) / 4;

    const ENTITY_OFFSET = std.math.maxInt(@typeInfo(@FieldType(@This(), "reserved")).@"enum".tag_type) + 1;
    const DENSE_COMPONENT_OFFSET = ENTITY_OFFSET + OFFSET;
    const SPARSE_COMPONENT_OFFSET = DENSE_COMPONENT_OFFSET + OFFSET / 2;
    const SYSTEM_OFFSET = DENSE_COMPONENT_OFFSET + OFFSET;
    const EVENT_OFFSET = SYSTEM_OFFSET + OFFSET;

    fn is_component(self: DecodedRef) bool {
        return self == .sparse_component or self == .dense_component;
    }

    pub fn decode(id: u64) DecodedRef {
        switch (id) {
            0...ENTITY_OFFSET - 1 => return DecodedRef{ .reserved = @enumFromInt(id) },
            ENTITY_OFFSET...DENSE_COMPONENT_OFFSET - 1 => {
                return .{ .entity = id - ENTITY_OFFSET };
            },
            DENSE_COMPONENT_OFFSET...SPARSE_COMPONENT_OFFSET - 1 => {
                return .{ .dense_component = id - DENSE_COMPONENT_OFFSET };
            },
            SPARSE_COMPONENT_OFFSET...SYSTEM_OFFSET - 1 => {
                return .{ .sparse_component = id - SPARSE_COMPONENT_OFFSET };
            },
            SYSTEM_OFFSET...EVENT_OFFSET - 1 => {
                return .{ .system = id - SYSTEM_OFFSET };
            },
            else => return .{ .event = id - EVENT_OFFSET },
        }
    }

    pub fn encode(self: DecodedRef) u64 {
        switch (self) {
            .reserved => |x| return @intFromEnum(x),
            .entity => |x| return x + ENTITY_OFFSET,
            .dense_component => |x| return x + DENSE_COMPONENT_OFFSET,
            .sparse_component => |x| return x + SPARSE_COMPONENT_OFFSET,
            .system => |x| return x + SYSTEM_OFFSET,
            .event => |x| return x + EVENT_OFFSET,
        }
    }

    pub const none: DecodedRef = .{ .reserved = .none };
};

const ComponentStore = struct {
    const MAX_ALLIGNMENT = std.mem.Alignment.@"64";

    const Info = struct {
        kind: ComponentRef,
        body_type: std.builtin.TypeId,
        body_size: usize,
        body_align: usize,
        name: ?[]const u8,
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
        ref.parent.* = DecodedRef.none.encode();
        self.freelist.append(ecs.gpa, idx) catch |err| {
            Log.log(.warn, "{*}: failed to add a Component to the freelist: {}", .{ self, err });
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
    stack: std.ArrayListUnmanaged(*System),
    queue: Queue(*System),

    const System = struct {
        id: SystemRef,
        name: ?[]const u8,
        requirements: ?*Edge,
        status: u8,

        data: *anyopaque,
        callback: *const fn (data: *anyopaque, ecs: *Ecs, eid: EntityRef) void,
        query: []const ComponentRef,

        const ALIVE_BIT: u8 = 0x01;
        const VISITED_BIT: u8 = 0x02;
        const COMPLETE_BIT: u8 = 0x04;
        const WORKING_BIT: u8 = 0x08;
        const DISABLED_BIT: u8 = 0x10;

        pub inline fn run(self: *System, ecs: *Ecs, eid: EntityRef) void {
            self.callback(self.data, ecs, eid);
        }
    };

    const Edge = struct {
        sys: *System,
        next: ?*Edge,
    };

    pub fn init() SystemStore {
        return .{
            .systems = .empty,
            .system_freelist = .empty,
            .edge_freelist = .empty,
            .stack = .empty,
            .queue = .empty,
        };
    }

    pub fn deinit(self: *SystemStore, gpa: std.mem.Allocator) void {
        self.systems.deinit(gpa);
        self.system_freelist.deinit(gpa);
        self.edge_freelist.deinit(gpa);
    }

    pub fn get(self: *SystemStore, ref: SystemRef) *System {
        return self.systems.items[DecodedRef.decode(ref).system];
    }

    pub fn add(self: *SystemStore, name: ?[]const u8, query: []const ComponentRef, ecs: *Ecs) !*System {
        const arena = ecs.arena.allocator();
        const static_query = try arena.dupe(ComponentRef, query);

        if (self.system_freelist.pop()) |old| {
            const sys: *System = self.systems.items[old];
            sys.id = old;
            sys.status = System.ALIVE_BIT;
            sys.name = name;
            sys.query = static_query;
            sys.requirements = null;

            return sys;
        } else {
            const sys: *System = try arena.create(System);
            sys.id = (DecodedRef{ .system = self.systems.items.len }).encode();
            sys.status = System.ALIVE_BIT;
            sys.name = name;
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
            Log.log(.warn, "{*}: failed to add System to the freelist: {}", .{err});
        };

        var cur = s.requirements;
        while (cur) |n| {
            cur = n.next;
            self.edge_freelist.append(ecs.gpa, n) catch |err| {
                Log.log(.warn, "{*}: failed to add Edge to the freelist: {}", .{err});
            };
        }
    }

    pub fn eval_order(self: *SystemStore, arena: std.mem.Allocator, before: SystemRef, after: SystemRef) !void {
        const a = self.get(before);
        const b = self.get(after);

        var cur = b.requirements;
        while (cur) |n| {
            cur = n.next;
            if (n.sys == a) return;
        }

        if (try self.reachable(arena, a, b)) return Error.SystemOrderLoop;
        for (self.systems.items) |s| s.status &= ~System.VISITED_BIT;

        const edge = if (self.edge_freelist.pop()) |old| old else try arena.create(Edge);
        edge.sys = a;
        edge.next = b.requirements;
        b.requirements = edge;
    }

    fn reachable(self: *SystemStore, gpa: std.mem.Allocator, start: *System, target: *System) !bool {
        const alloc = gpa;
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
        const alloc = ecs.arena.allocator();
        self.queue.clear();

        for (self.systems.items) |sys| {
            if (sys.status & System.ALIVE_BIT == 0) continue;
            if (sys.status & System.COMPLETE_BIT != 0) continue;
            if (sys.status & System.DISABLED_BIT != 0) continue;
            std.debug.assert(sys.status & System.WORKING_BIT == 0);

            try self.queue.push(alloc, sys);
            sys.status |= System.WORKING_BIT;

            while (self.queue.pop()) |cur| {
                var all_complete = true;
                var edge = cur.requirements;
                while (edge) |e| {
                    edge = e.next;
                    const next = e.sys;
                    if (next.status & System.COMPLETE_BIT != 0 or next.status & System.DISABLED_BIT != 0) {
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
        if (sys.status & System.DISABLED_BIT != 0) return;

        if (sys.query.len == 0) {
            for (ecs.entities.entities.items) |e| {
                if (e.alive) sys.run(ecs, e.eid);
            }
        } else {
            var start_store: *ComponentStore = undefined;
            var start_count: usize = std.math.maxInt(usize);
            for (sys.query) |kind| {
                const store = switch (DecodedRef.decode(kind)) {
                    .sparse_component => |x| &ecs.sparse_components.items[x],
                    .dense_component => |x| &ecs.dense_components.items[x],
                    else => std.debug.panic("{*}: access invalid component", .{self}),
                };
                if (store.count() < start_count) {
                    start_count = store.count();
                    start_store = store;
                }
            }

            outer: for (start_store.parents.items) |parent| {
                if (DecodedRef.decode(parent) == .reserved) continue;
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
        try writer.print("{}", .{DecodedRef.decode(self.eid)});
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
        switch (DecodedRef.decode(kind)) {
            .sparse_component => {
                var cur = self.sparse;
                while (cur) |node| {
                    cur = node.next;
                    if (node.kind == kind) {
                        return node.idx;
                    }
                }
                return null;
            },
            .dense_component => |id| {
                if (self.dense.items.len <= id or self.dense.items[id] == 0) {
                    return null;
                } else {
                    return self.dense.items[id] - 1;
                }
            },
            else => std.debug.panic("{*}: invalid component, should be unreachable", .{ecs}),
        }
    }

    pub fn add(self: *ComponentSet, ecs: *Ecs, kind: ComponentRef, idx: usize) !void {
        switch (DecodedRef.decode(kind)) {
            .sparse_component => {
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
            .dense_component => |id| {
                if (self.dense.items.len <= id) {
                    try self.dense.appendNTimes(
                        ecs.gpa,
                        0,
                        ecs.dense_components.items.len - self.dense.items.len,
                    );
                }
                self.dense.items[id] = idx + 1;
            },
            else => std.debug.panic("{*}: invalid component, should be unreachable", .{ecs}),
        }
    }

    pub fn remove(self: *ComponentSet, ecs: *Ecs, kind: ComponentRef) ?usize {
        switch (DecodedRef.decode(kind)) {
            .sparse_component => {
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
                            Log.log(.warn, "{*}: failed to add a SparseNode to the freelist: {}", .{ ecs, err });
                        };
                        return res;
                    }
                    prev = n;
                }
            },
            .dense_component => |id| {
                if (self.dense.items.len <= id) {
                    return null;
                }
                const res = self.dense.items[id];
                self.dense.items[id] = 0;
                if (res == 0) return null;
                return res - 1;
            },
            else => std.debug.panic("{*}: invalid component, should be unreachable", .{ecs}),
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
                Log.log(.warn, "{*}: failed to add a SparseNode to the freelist: {}", .{ ecs, err });
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
                                .kind = (DecodedRef{ .dense_component = i }).encode(),
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
gpa: std.mem.Allocator,
events: std.ArrayListUnmanaged(EventData),

names: std.StringHashMapUnmanaged(u64),
arena: std.heap.ArenaAllocator,

const EventData = struct {
    component: ComponentRef,
    system: SystemRef,
    bodies: std.ArrayListAlignedUnmanaged(u8, std.mem.Alignment.@"64"),

    pub fn deinit(self: *EventData, gpa: std.mem.Allocator) void {
        self.bodies.deinit(gpa);
    }
};

const Self = @This();
const Ecs = @This();
pub fn init(gpa: std.mem.Allocator) Self {
    return .{
        .gpa = gpa,
        .entities = .init(gpa),
        .systems = .init(),
        .dense_components = .empty,
        .sparse_components = .empty,
        .events = .empty,
        .names = .empty,
        .arena = .init(gpa),
    };
}

pub fn deinit(self: *Self) void {
    self.entities.deinit(self.gpa);
    self.systems.deinit(self.gpa);
    for (self.dense_components.items) |*s| s.deinit(self.gpa);
    for (self.sparse_components.items) |*s| s.deinit(self.gpa);
    for (self.events.items) |*evt_data| evt_data.deinit(self.gpa);
    self.events.deinit(self.gpa);
    self.dense_components.deinit(self.gpa);
    self.sparse_components.deinit(self.gpa);
    self.names.deinit(self.gpa);
    self.arena.deinit();
}

const NamedEntry = struct {
    name: ?[]const u8,
    val: *u64,
};
var dummy_id: u64 = 0;

fn ensure_new_name(self: *Self, name: ?[]const u8) !NamedEntry {
    const n = name orelse return .{ .name = null, .val = &dummy_id };
    const entry = try self.names.getOrPut(self.gpa, n);
    if (entry.found_existing) return Error.NameAlreadyDefined;
    entry.key_ptr.* = try self.arena.allocator().dupe(u8, n);
    return .{ .name = entry.key_ptr.*, .val = entry.value_ptr };
}

pub fn register_component(
    self: *Self,
    name: ?[]const u8,
    comptime Body: type,
    is_sparse: bool,
) Error!ComponentRef {
    const named_entry = try self.ensure_new_name(name);

    const info = if (is_sparse) blk: {
        const info = ComponentStore.Info{
            .kind = (DecodedRef{ .sparse_component = self.sparse_components.items.len }).encode(),
            .name = named_entry.name,
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
            .kind = (DecodedRef{ .dense_component = self.dense_components.items.len }).encode(),
            .name = named_entry.name,
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
    named_entry.val.* = info.kind;

    Log.log(
        .debug,
        "{*}: Registered new component: \"{?s}\", kind: {}",
        .{ self, name, DecodedRef.decode(info.kind) },
    );

    return info.kind;
}

pub fn spawn(self: *Self) Error!EntityRef {
    if (self.entities.free_entities.pop()) |old| {
        const eid = DecodedRef.decode(old);
        if (Options.ecs_logging) {
            Log.log(.debug, "{*}: reusing old entity {}", .{ self, eid });
        }
        const e = &self.entities.entities.items[eid.entity];
        e.eid = old;
        e.alive = true;
        return e.eid;
    } else {
        const eid = DecodedRef{ .entity = self.entities.entities.items.len };
        if (Options.ecs_logging) {
            Log.log(.debug, "{*}: spawn new entity {}", .{ self, eid });
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
    const decoded = DecodedRef.decode(eid);
    switch (decoded.index) {
        .entity => |idx| return &self.entities.entities.items[idx],
        else => return Error.InvalidEntity,
    }
}
fn get_entity_ensure_alive(self: *Self, eid: EntityRef) Error!*Entity {
    const decoded = DecodedRef.decode(eid);
    switch (decoded) {
        else => return Error.InvalidEntity,
        .entity => |idx| {
            const e = &self.entities.entities.items[idx];
            if (e.eid != eid or !e.alive) return Error.DeadEntity;
            return e;
        },
    }
}

pub fn kill(self: *Self, eid: EntityRef) void {
    const e = self.get_entity_ensure_alive(eid) catch |err| {
        Log.log(.warn, "{*}: tried to kill an invalid entity {d}: {}", .{ self, eid, err });
        return;
    };
    if (Options.ecs_logging) {
        Log.log(.debug, "{*}: killing entity {f}", .{ self, e });
    }
    var it = e.components.iter(self);

    while (it.next()) |entry| {
        self.remove_component(e.eid, entry.kind);
    }
    e.components.clear(self);
    e.alive = false;

    self.entities.free_entities.append(self.gpa, eid) catch |err| {
        Log.log(.warn, "{*}: failed to add Entity to a freelist: {}", .{ self, err });
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
        Log.log(.debug, "{*}: adding component {} to entity {f}", .{ self, DecodedRef.decode(kind), e });
    }

    const store: *ComponentStore = switch (DecodedRef.decode(kind)) {
        else => return Error.InvalidComponent,
        .sparse_component => |idx| &self.sparse_components.items[idx],
        .dense_component => |idx| &self.dense_components.items[idx],
    };

    if (Options.ecs_typecheck) {
        if (@typeInfo(T) != store.info.body_type) {
            Log.log(.err, "{*}: failed to typecheck component {}, expected {}, got {}", .{
                self,
                DecodedRef.decode(kind),
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
        Log.log(.warn, "{*}: attempted to remove component from an invalid entity {}: {}", .{
            self,
            DecodedRef.decode(eid),
            err,
        });
        return;
    };
    if (Options.ecs_logging) {
        Log.log(.debug, "{*}: removing component {} from entity {f}", .{ self, DecodedRef.decode(kind), e });
    }
    const store = switch (DecodedRef.decode(kind)) {
        .sparse_component => |x| &self.sparse_components.items[x],
        .dense_component => |x| &self.dense_components.items[x],
        else => {
            Log.log(.warn, "{*}: attempted to remove an invalid component {}", .{ self, kind });
            return;
        },
    };
    const idx = e.components.remove(self, kind) orelse {
        Log.log(.warn, "{*}: entity {f} did not have a component {}", .{
            self,
            e,
            DecodedRef.decode(kind),
        });
        return;
    };
    store.remove(self, idx);
}

pub fn has_component(self: *Self, eid: EntityRef, kind: ComponentRef) bool {
    const e = self.get_entity_ensure_alive(eid) catch |err| {
        Log.log(.warn, "{*}: accessing an invalid entity {}: {}", .{ self, DecodedRef.decode(eid), err });
        return false;
    };
    if (Options.ecs_logging) {
        Log.log(.debug, "{*}: Check if entity {f} has component {}", .{ self, e, DecodedRef.decode(kind) });
    }
    if (!DecodedRef.decode(kind).is_component()) {
        Log.log(.warn, "{*}: accessing invalid component {d}", .{ self, kind });
        return false;
    }
    return e.components.get(self, kind) != null;
}

pub fn get_component(self: *Self, eid: EntityRef, comptime T: type, kind: ComponentRef) ?*T {
    const e = self.get_entity_ensure_alive(eid) catch |err| {
        Log.log(.warn, "{*}: accessing an invalid entity {}: {}", .{ self, DecodedRef.decode(eid), err });
        return null;
    };
    if (Options.ecs_logging) {
        Log.log(.debug, "{*}: get component {} of entity {f}", .{ self, DecodedRef.decode(kind), e });
    }
    const store: *ComponentStore = switch (DecodedRef.decode(kind)) {
        else => {
            Log.log(.warn, "{*}: accessing invalid component {d}", .{ self, kind });
            return null;
        },
        .sparse_component => |idx| &self.sparse_components.items[idx],
        .dense_component => |idx| &self.dense_components.items[idx],
    };
    if (Options.ecs_typecheck) {
        if (@typeInfo(T) != store.info.body_type) {
            Log.log(.err, "{*}: failed to typecheck component {}, expected {}, got {}", .{
                self,
                DecodedRef.decode(kind),
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
        Log.log(.warn, "{*}: accessing an invalid entity {}: {}", .{ self, DecodedRef.decode(eid), err });
        return .invalid;
    };
    return .{ .valid = e.components.iter(self) };
}

pub fn register_system(
    self: *Self,
    comptime Ctx: type,
    name: ?[]const u8,
    query: []const ComponentRef,
    ctx: Ctx,
    callback: *const fn (ctx: Ctx, ecs: *Ecs, eid: EntityRef) void,
) Error!SystemRef {
    const named_entry = try self.ensure_new_name(name);

    const sys = try self.systems.add(named_entry.name, query, self);
    named_entry.val.* = sys.id;

    if (@typeInfo(Ctx) == .pointer) {
        sys.data = @ptrCast(ctx);
        sys.callback = @ptrCast(callback);
    } else {
        const Data = struct { Ctx, @TypeOf(callback) };
        const ptr = try self.arena.allocator().create(Data);
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

pub fn disable_system(self: *Self, sys: SystemRef) void {
    const s = self.systems.get(sys);
    s.status |= SystemStore.System.DISABLED_BIT;
}

pub fn enable_system(self: *Self, sys: SystemRef) void {
    const s = self.systems.get(sys);
    s.status &= ~SystemStore.System.DISABLED_BIT;
}

pub fn ensure_eval_order(self: *Self, before: SystemRef, after: SystemRef) Error!void {
    try self.systems.eval_order(self.arena.allocator(), before, after);
}

pub fn evaluate(self: *Self) Error!void {
    try self.systems.eval(self);
    for (self.events.items) |*evt_data| {
        evt_data.bodies.clearRetainingCapacity();
        self.disable_system(evt_data.system);
    }
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
    try std.testing.expect(.dense_component == DecodedRef.decode(pos));
    try std.testing.expect(.dense_component == DecodedRef.decode(vel));
    try std.testing.expect(.dense_component == DecodedRef.decode(name));
    try std.testing.expect(.sparse_component == DecodedRef.decode(player_tag));
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
    try std.testing.expect(ecs.is_alive(player));

    try ecs.add_component(player, Vec3f, pos, .{ 0, 10, 0 });
    try ecs.add_component(player, []const u8, name, "Player");
    try ecs.add_component(player, void, player_tag, {});

    try std.testing.expectEqual(.{ 0, 10, 0 }, ecs.get_component(player, Vec3f, pos).?.*);
    try std.testing.expectEqual(null, ecs.get_component(player, Vec3f, vel));
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

test "Ecs.add_component replacement" {
    var ecs = Ecs.init(std.testing.allocator);
    defer ecs.deinit();

    const Vec3f = @Vector(3, f32);
    const pos = try ecs.register_component("Position", Vec3f, false);
    const player = try ecs.spawn();
    try ecs.add_component(player, Vec3f, pos, .{ 0, 0, 0 });
    try std.testing.expectEqual(.{ 0, 0, 0 }, ecs.get_component(player, Vec3f, pos).?.*);
    try ecs.add_component(player, Vec3f, pos, .{ 0, 1, 0 });
    try std.testing.expectEqual(.{ 0, 1, 0 }, ecs.get_component(player, Vec3f, pos).?.*);
}

const EventComponent = struct {
    data: *anyopaque,
    callback: *const fn (*anyopaque, []u8) void,
};
pub fn register_event(self: *Self, name: ?[]const u8, comptime Body: type) Error!EventRef {
    const named_entry = try self.ensure_new_name(name);

    const event = (DecodedRef{ .event = self.events.items.len }).encode();
    named_entry.val.* = event;

    const component = try self.register_component(null, EventComponent, true);
    const evt_data = try self.events.addOne(self.gpa);
    evt_data.component = component;

    evt_data.system = try self.register_system(EventRef, null, &.{component}, event, &struct {
        fn callback(evt: EventRef, ecs: *Ecs, eid: EntityRef) void {
            const comp = ecs.get_event_component(evt) catch unreachable;
            const cb = ecs.get_component(eid, EventComponent, comp).?.*;
            const bodies = ecs.get_event_queue(Body, evt).?;
            var bodies_raw_array: []u8 = undefined;
            bodies_raw_array.len = bodies.len;
            bodies_raw_array.ptr = @ptrCast(bodies.ptr);
            cb.callback(cb.data, bodies_raw_array);
        }
    }.callback);
    evt_data.bodies = .empty;
    self.disable_system(evt_data.system);

    return event;
}

pub fn add_event_listener(
    self: *Self,
    eid: EntityRef,
    comptime Body: type,
    comptime Ctx: type,
    event: EventRef,
    ctx: Ctx,
    callback: *const fn (Ctx, []Body) void,
) Error!void {
    const comp = try self.get_event_component(event);
    if (@typeInfo(Ctx) == .pointer) {
        try self.add_component(eid, EventComponent, comp, EventComponent{
            .callback = @ptrCast(callback),
            .data = @ptrCast(ctx),
        });
    } else {
        const HeapCtx = struct {
            ctx: Ctx,
            callback: @TypeOf(callback),
        };
        const ctx_ref = try self.gpa.create(HeapCtx);
        ctx_ref.ctx = ctx;
        ctx_ref.callback = callback;
        try self.add_component(eid, EventComponent, comp, .{
            .data = @ptrCast(ctx_ref),
            .callback = @ptrCast(&struct {
                fn heap_callback(hc: HeapCtx, body: []Body) void {
                    hc.callback(ctx.ctx, body);
                }
            }.heap_callback),
        });
    }
}

pub fn remove_event_listener(self: *Self, eid: EntityRef, event: EventRef) void {
    const comp = self.get_event_component(event) catch return;
    self.remove_component(eid, comp);
}

pub fn emit_event(self: *Self, comptime Body: type, event: EventRef, body: Body) Error!void {
    const decoded = DecodedRef.decode(event);
    if (decoded != .event) {
        Log.log(.warn, "{*}: Access invalid event {}", .{ self, decoded });
        return Error.InvalidEvent;
    }
    const idx = decoded.event;
    const evt_data = &self.events.items[idx];
    try evt_data.bodies.appendSlice(self.gpa, &std.mem.toBytes(body));
    self.enable_system(evt_data.system);
}

pub fn get_event_system(self: *Self, event: EventRef) Error!SystemRef {
    const decoded = DecodedRef.decode(event);
    if (decoded != .event) {
        Log.log(.warn, "{*}: Access invalid event {}", .{ self, decoded });
        return Error.InvalidEvent;
    }
    const idx = decoded.event;
    const evt_data = &self.events.items[idx];
    return evt_data.system;
}

fn get_event_component(self: *Self, event: EventRef) Error!SystemRef {
    const decoded = DecodedRef.decode(event);
    if (decoded != .event) {
        Log.log(.warn, "{*}: Access invalid event {}", .{ self, decoded });
        return Error.InvalidEvent;
    }
    const idx = decoded.event;
    const evt_data = &self.events.items[idx];
    return evt_data.component;
}

fn get_event_queue(self: *Self, comptime Body: type, event: EventRef) ?[]Body {
    const decoded = DecodedRef.decode(event);
    if (decoded != .event) {
        Log.log(.warn, "{*}: Access invalid event {}", .{ self, decoded });
        return null;
    }
    const idx = decoded.event;
    const evt_data = &self.events.items[idx];
    return @ptrCast(evt_data.bodies.items);
}

test "Ecs.register_event" {
    var ecs = Ecs.init(std.testing.allocator);
    defer ecs.deinit();

    const evt = try ecs.register_event("add", usize);
    const player = try ecs.spawn();

    const PlayerEventListener = struct {
        sum: usize = 0,
        ran: bool = false,
        fn on_event(self: *@This(), nums: []usize) void {
            if (!self.ran) {
                self.ran = true;
                self.sum = 0;
            }
            for (nums) |n| self.sum += n;
        }
    };
    var listener = PlayerEventListener{};
    try ecs.add_event_listener(player, usize, *PlayerEventListener, evt, &listener, &PlayerEventListener.on_event);

    try ecs.emit_event(usize, evt, 10);
    try ecs.evaluate();
    try std.testing.expect(listener.ran);
    try std.testing.expectEqual(10, listener.sum);
    listener.ran = false;

    try ecs.evaluate();
    try std.testing.expect(!listener.ran);
    listener.ran = false;

    try ecs.emit_event(usize, evt, 10);
    try ecs.emit_event(usize, evt, 20);
    try ecs.emit_event(usize, evt, 30);
    try ecs.evaluate();
    try std.testing.expect(listener.ran);
    try std.testing.expectEqual(60, listener.sum);
    listener.ran = false;
}
