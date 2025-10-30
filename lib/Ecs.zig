const std = @import("std");
const StringStore = @import("StringStore.zig");
const Options = @import("Options");
const Log = @import("Log.zig");

pub const EntityRef = u64;
pub const SystemRef = u64;
pub const ComponentRef = u64;

pub const Error = error{
    ComponentAlreadyDefined,
} || std.mem.Allocator.Error;

const DecodedComponentRef = union(enum) {
    const DENSE_OFFSET = std.math.maxInt(@typeInfo(@FieldType(DecodedComponentRef, "reserved")).@"enum".tag_type) + 1;
    const SPARSE_OFFSET = (1 << 63) + 1;

    reserved: enum(u8) { invalid, _ },
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
        return .{
            .generation = @intCast(id & GEN_MASK),
            .index = @enumFromInt(id >> GEN_SIZE),
        };
    }

    pub fn encode(self: DecodedEntityRef) EntityRef {
        return @as(EntityRef, @intCast(self.generation)) | (@as(EntityRef, @intFromEnum(self.index)) << GEN_SIZE);
    }

    const Index = enum(IndexInt) {
        const RESERVED_CNT = @intFromEnum(Index.last_reserved) + 1;
        none = 0,
        last_reserved = 1023,
        _,

        pub fn as_index(self: Index) usize {
            return @intFromEnum(self) - RESERVED_CNT;
        }
        pub fn from_index(idx: usize) Index {
            return @enumFromInt(idx + RESERVED_CNT);
        }
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
            const idx = self.length();
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

    pub fn length(self: *ComponentStore) usize {
        return self.parents.items.len;
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
    system_freelist: std.ArrayListUnmanaged(*System),
    arena: std.heap.ArenaAllocator,

    const System = struct {
        name: []const u8,
        data: *anyopaque,
        vtable: *const VTable,
        query: []const ComponentRef,

        run_before: ?*Edge,
        run_after: ?*Edge,

        const VTable = struct {
            callback: *const fn (data: *anyopaque, ecs: *Ecs, eid: EntityRef) void,
        };
    };
    const Edge = struct {
        sys: *System,
        next: *Edge,
    };

    pub fn init(gpa: std.mem.Allocator) SystemStore {
        return .{
            .systems = .empty,
            .system_freelist = .empty,
            .edge_freelist = .empty,
            .arena = .init(gpa),
        };
    }

    pub fn deinit(self: *SystemStore, gpa: std.mem.Allocator) void {
        self.systems.deinit(gpa);
        self.system_freelist.deinit(gpa);
        self.edge_freelist.deinit(gpa);
        self.arena.deinit();
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
        const idx = eid.index.as_index();
        const e = &self.entities.entities.items[idx];
        e.eid = eid.encode();
        e.alive = true;
        return e.eid;
    } else {
        const eid = DecodedEntityRef.from_parts(.from_index(self.entities.entities.items.len), 0);
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

pub fn kill(self: *Self, eid: EntityRef) void {
    const decoded = DecodedEntityRef.decode(eid);
    if (Options.ecs_logging) {
        Log.log(.debug, "Ecs@{*}: killing entity {f}", .{ self, decoded });
    }
    const e = &self.entities.entities.items[decoded.index.as_index()];
    e.alive = false;
    var it = e.components.iter(self);

    while (it.next()) |entry| {
        self.remove_component(e.eid, entry.kind);
    }
    e.components.clear(self);

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
    const decoded = DecodedEntityRef.decode(eid);
    if (Options.ecs_logging) {
        Log.log(.debug, "Ecs@{*}: adding component {} to entity {f}", .{ self, DecodedComponentRef.decode(kind), decoded });
    }
    const e = &self.entities.entities.items[decoded.index.as_index()];

    const store: *ComponentStore = switch (DecodedComponentRef.decode(kind)) {
        .reserved => std.debug.panic("Ecs@{*}: access invalid component", .{self}),
        .sparse => |idx| &self.sparse_components.items[idx],
        .dense => |idx| &self.dense_components.items[idx],
    };

    if (Options.ecs_typecheck) {
        if (@typeInfo(T) != store.info.body_type) {
            std.debug.panic("Ecs@{*}: failed to typecheck component {}, expected {}, got {}", .{
                self,
                DecodedComponentRef.decode(kind),
                store.info.body_type,
                std.meta.activeTag(@typeInfo(T)),
            });
        }
    }

    const ref = try store.add(self);
    @memcpy(ref.data, std.mem.asBytes(&body));
    ref.parent.* = eid;
    try e.components.add(self, kind, ref.idx);
}

pub fn remove_component(self: *Self, eid: EntityRef, kind: ComponentRef) void {
    const decoded = DecodedEntityRef.decode(eid);
    if (Options.ecs_logging) {
        Log.log(.debug, "Ecs@{*}: removing component {} from entity {f}", .{ self, DecodedComponentRef.decode(kind), decoded });
    }
    const e = &self.entities.entities.items[decoded.index.as_index()];
    const idx = e.components.remove(self, kind) orelse {
        if (Options.ecs_logging) {
            Log.log(.debug, "Ecs@{*}: entity {f} did not have a component {}", .{
                self,
                decoded,
                DecodedComponentRef.decode(kind),
            });
        }
        return;
    };

    switch (DecodedComponentRef.decode(kind)) {
        .reserved => std.debug.panic("Ecs@{*}: accessing invalid component", .{self}),
        .sparse => |x| {
            self.sparse_components.items[x].remove(self, idx);
        },
        .dense => |x| {
            self.dense_components.items[x].remove(self, idx);
        },
    }
}

pub fn has_component(self: *Self, eid: EntityRef, kind: ComponentRef) bool {
    const decoded = DecodedEntityRef.decode(eid);
    if (Options.ecs_logging) {
        Log.log(.debug, "Ecs@{*}: Check if entity {f} has component {}", .{ self, decoded, DecodedComponentRef.decode(kind) });
    }
    const e = &self.entities.entities.items[decoded.index.as_index()];
    return e.components.get(self, kind) != null;
}

pub fn get_component(self: *Self, eid: EntityRef, comptime T: type, kind: ComponentRef) ?*T {
    const decoded = DecodedEntityRef.decode(eid);
    if (Options.ecs_logging) {
        Log.log(.debug, "Ecs@{*}: get component {} of entity {f}", .{ self, DecodedComponentRef.decode(kind), decoded });
    }
    const e = &self.entities.entities.items[decoded.index.as_index()];
    const store: *ComponentStore = switch (DecodedComponentRef.decode(kind)) {
        .reserved => std.debug.panic("Ecs@{*}: access invalid component", .{self}),
        .sparse => |idx| &self.sparse_components.items[idx],
        .dense => |idx| &self.dense_components.items[idx],
    };

    const idx = e.components.get(self, kind) orelse return null;
    const ref = store.get(idx);

    if (Options.ecs_typecheck) {
        if (@typeInfo(T) != store.info.body_type) {
            std.debug.panic("Ecs@{*}: failed to typecheck component {}, expected {}, got {}", .{
                self,
                DecodedComponentRef.decode(kind),
                store.info.body_type,
                std.meta.activeTag(@typeInfo(T)),
            });
        }
        if (ref.parent.* != eid) {
            std.debug.panic("Ecs@{*}: component {}@{d} parent mismatch: expected {f}, got {f}", .{
                self,
                DecodedComponentRef.decode(kind),
                ref.idx,
                DecodedEntityRef.decode(ref.parent.*),
                DecodedEntityRef.decode(eid),
            });
        }
    }

    return @ptrCast(@alignCast(ref.data));
}

pub fn is_alive(self: *Self, eid: EntityRef) bool {
    const decoded = DecodedEntityRef.decode(eid);
    const e = &self.entities.entities.items[decoded.index.as_index()];
    return e.alive and e.eid == eid;
}

const ComponentIter = struct {
    inner: ComponentSet.Iter,

    pub inline fn next(self: *ComponentIter) ?ComponentRef {
        const entry = self.inner.next() orelse return null;
        return entry.kind;
    }
};

pub fn iterate_components(self: *Self, eid: EntityRef) ComponentIter {
    const decoded = DecodedEntityRef.decode(eid);
    const e = &self.entities.entities.items[decoded.index.as_index()];
    return .{ .inner = e.components.iter(self) };
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
