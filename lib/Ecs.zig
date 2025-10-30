const std = @import("std");
const StringStore = @import("StringStore.zig");
const Options = @import("Options");
const Log = @import("Log.zig");

pub const ComponentKind = enum(u64) {
    const DENSE_OFFSET: u64 = @intFromEnum(ComponentKind.last_reserved) + 1;
    const SPARSE_OFFSET: u64 = @intFromEnum(ComponentKind.last_dense) + 1;
    invalid = 0,
    last_reserved = 1023,
    last_dense = 1 << 63,
    _,

    pub fn init(idx: usize, sparse: bool) ComponentKind {
        if (sparse) {
            return @enumFromInt(idx + SPARSE_OFFSET);
        } else {
            return @enumFromInt(idx + DENSE_OFFSET);
        }
    }

    const Decoded = union(enum) { reserved: u64, dense: u64, sparse: u64 };
    pub fn decode(self: ComponentKind) Decoded {
        const raw: u64 = @intFromEnum(self);
        if (raw < DENSE_OFFSET) {
            return .{ .reserved = raw };
        } else if (raw < SPARSE_OFFSET) {
            return .{ .dense = raw - DENSE_OFFSET };
        } else {
            return .{ .sparse = raw - SPARSE_OFFSET };
        }
    }

    pub fn is_sparse(self: ComponentKind) bool {
        return @as(std.meta.Tag(Decoded), self.decode()) == .sparse;
    }

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("{}", .{self.decode()});
    }
};

pub const EId = u64;

pub const Error = error{
    ComponentAlreadyDefined,
} || std.mem.Allocator.Error;

const DecodedId = struct {
    const INDEX_SIZE = 56;
    const GEN_SIZE = @typeInfo(EId).int.bits - INDEX_SIZE;
    const GenInt = std.meta.Int(.unsigned, GEN_SIZE);
    const IndexInt = std.meta.Int(.unsigned, INDEX_SIZE);
    const GEN_MASK = std.math.boolMask(GenInt, true);

    index: Index,
    generation: GenInt,

    pub const empty: DecodedId = .{ .index = .none, .generation = 0 };

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("{s}{}@{}", .{ @typeName(EId), self.index, self.generation });
    }

    pub fn from_parts(index: Index, generation: GenInt) DecodedId {
        return .{
            .index = index,
            .generation = generation,
        };
    }

    pub fn increment_generation(self: DecodedId) DecodedId {
        return .{
            .index = self.index,
            .generation = self.generation +% 1,
        };
    }

    pub fn decode(id: EId) DecodedId {
        return .{
            .generation = @intCast(id & GEN_MASK),
            .index = @enumFromInt(id >> GEN_SIZE),
        };
    }

    pub fn encode(self: DecodedId) EId {
        return @as(EId, @intCast(self.generation)) | (@as(EId, @intFromEnum(self.index)) << GEN_SIZE);
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

const MAX_ALLIGNMENT = std.mem.Alignment.@"64";

const ComponentInfo = struct {
    kind: ComponentKind,
    body_type: std.builtin.TypeId,
    name: []const u8,
    size: Size,

    const Size = struct {
        size: usize,
        alignment: std.mem.Alignment,
        eid_offset: usize,
        data_offset: usize,
        data_size: usize,

        pub fn init(size: usize, alignment: usize) Size {
            var self = std.mem.zeroes(Size);
            self.data_size = size;
            self.alignment = std.mem.Alignment.fromByteUnits(@alignOf(EId));
            self.eid_offset = self.alignment.forward(0);
            self.data_offset = std.mem.Alignment.fromByteUnits(alignment)
                .forward(self.eid_offset + @sizeOf(EId));
            self.size = self.alignment.forward(self.data_offset + self.data_size);

            if (Options.ecs_logging) {
                Log.log(.debug, "new ecs component: size={d},align={d}=>{}", .{ size, alignment, self });
            }

            return self;
        }
    };
};

const ComponentStore = struct {
    info: ComponentInfo,
    data: std.ArrayListAlignedUnmanaged(u8, MAX_ALLIGNMENT),
    freelist: std.ArrayListUnmanaged(usize),

    pub fn deinit(self: *ComponentStore, gpa: std.mem.Allocator) void {
        self.data.deinit(gpa);
        self.freelist.deinit(gpa);
    }

    pub fn remove(self: *ComponentStore, ecs: *Ecs, idx: usize) void {
        const ref = self.get(idx);
        ref.parent.* = DecodedId.empty.encode();
        self.freelist.append(ecs.gpa, idx) catch |err| {
            Log.log(.warn, "Ecs@{*}: failed to add a Component to the freelist: {}", .{ self, err });
        };
    }

    pub fn add(self: *ComponentStore, ecs: *Ecs) Error!Ref {
        if (self.freelist.pop()) |idx| {
            return self.get(idx);
        } else {
            const idx = self.length();
            _ = try self.data.addManyAsSlice(ecs.gpa, self.info.size.size);
            return self.get(idx);
        }
    }

    const Ref = struct {
        idx: usize,
        parent: *EId,
        data: []u8,
    };

    pub fn length(self: *ComponentStore) usize {
        return self.data.items.len / self.info.size.size;
    }

    pub fn get(self: *ComponentStore, idx: usize) Ref {
        const info = self.info.size;
        const slice: []u8 = self.data.items[idx * info.size .. (idx + 1) * info.size];
        const eid: *EId = @ptrCast(@alignCast(slice[info.eid_offset .. info.eid_offset + @sizeOf(EId)]));
        return .{
            .idx = idx,
            .parent = eid,
            .data = slice[info.data_offset .. info.data_offset + info.data_size],
        };
    }
};

const SystemStore = struct {
    const empty: SystemStore = .{};
    pub fn deinit(self: *SystemStore, gpa: std.mem.Allocator) void {
        _ = self;
        _ = gpa;
    }
};

const EntityStore = struct {
    entities: std.ArrayListUnmanaged(Entity),
    free_entities: std.ArrayListUnmanaged(EId),
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
    eid: EId,
    components: ComponentSet,
    alive: bool,

    pub fn deinit(self: *Entity, gpa: std.mem.Allocator) void {
        self.components.deinit(gpa);
    }
};

const SparseNode = struct {
    kind: ComponentKind,
    idx: usize,
    next: ?*SparseNode,
};

const ComponentSet = struct {
    dense: std.ArrayListUnmanaged(usize),
    sparse: ?*SparseNode,

    pub const empty: ComponentSet = .{ .sparse = null, .dense = .empty };

    pub fn get(self: *ComponentSet, ecs: *Ecs, kind: ComponentKind) ?usize {
        const decoded = kind.decode();
        switch (decoded) {
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

    pub fn add(self: *ComponentSet, ecs: *Ecs, kind: ComponentKind, idx: usize) !void {
        const decoded = kind.decode();
        switch (decoded) {
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

    pub fn remove(self: *ComponentSet, ecs: *Ecs, kind: ComponentKind) ?usize {
        const decoded = kind.decode();
        switch (decoded) {
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
            kind: ComponentKind,
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
                                .kind = ComponentKind.init(i, false),
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
        .systems = .empty,
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
) Error!ComponentKind {
    if (self.component_names.contains(name)) {
        return Error.ComponentAlreadyDefined;
    }
    const static_name = try self.component_names.ensure_stored(self.gpa, name);
    const info = if (is_sparse) blk: {
        const info = ComponentInfo{
            .kind = ComponentKind.init(self.sparse_components.items.len, true),
            .name = static_name,
            .body_type = @typeInfo(Body),
            .size = .init(@sizeOf(Body), @alignOf(Body)),
        };

        try self.sparse_components.append(self.gpa, .{
            .info = info,
            .data = .empty,
            .freelist = .empty,
        });
        break :blk info;
    } else blk: {
        const info = ComponentInfo{
            .kind = ComponentKind.init(self.dense_components.items.len, false),
            .body_type = @typeInfo(Body),
            .size = .init(@sizeOf(Body), @alignOf(Body)),
            .name = static_name,
        };

        try self.dense_components.append(self.gpa, .{
            .info = info,
            .data = .empty,
            .freelist = .empty,
        });
        break :blk info;
    };

    if (Options.ecs_logging) {
        Log.log(.debug, "Ecs@{*}: Registered new component: \"{s}\", kind: {f}", .{ self, name, info.kind });
    }

    return info.kind;
}

pub fn spawn(self: *Self) Error!EId {
    if (self.entities.free_entities.pop()) |old| {
        const eid = DecodedId.decode(old).increment_generation();
        if (Options.ecs_logging) {
            Log.log(.debug, "Ecs@{*}: reusing old entity {f}", .{ self, eid });
        }
        const idx = eid.index.as_index();
        const e = &self.entities.entities.items[idx];
        e.eid = eid.encode();
        e.alive = true;
        return e.eid;
    } else {
        const eid = DecodedId.from_parts(.from_index(self.entities.entities.items.len), 0);
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

pub fn kill(self: *Self, eid: EId) void {
    const decoded = DecodedId.decode(eid);
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
    eid: EId,
    comptime T: type,
    kind: ComponentKind,
    body: T,
) Error!void {
    const decoded = DecodedId.decode(eid);
    if (Options.ecs_logging) {
        Log.log(.debug, "Ecs@{*}: adding component {f} to entity {f}", .{ self, kind, decoded });
    }
    const e = &self.entities.entities.items[decoded.index.as_index()];

    const store: *ComponentStore = switch (kind.decode()) {
        .reserved => std.debug.panic("Ecs@{*}: access invalid component", .{self}),
        .sparse => |idx| &self.sparse_components.items[idx],
        .dense => |idx| &self.dense_components.items[idx],
    };

    if (Options.ecs_typecheck) {
        if (@typeInfo(T) != store.info.body_type) {
            std.debug.panic("Ecs@{*}: failed to typecheck component {f}, expected {}, got {}", .{
                self,
                kind,
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

pub fn remove_component(self: *Self, eid: EId, kind: ComponentKind) void {
    const decoded = DecodedId.decode(eid);
    if (Options.ecs_logging) {
        Log.log(.debug, "Ecs@{*}: removing component {f} from entity {f}", .{ self, kind, decoded });
    }
    const e = &self.entities.entities.items[decoded.index.as_index()];
    const idx = e.components.remove(self, kind) orelse {
        if (Options.ecs_logging) {
            Log.log(.debug, "Ecs@{*}: entity {f} did not have a {f}", .{ self, decoded, kind });
        }
        return;
    };

    if (kind.is_sparse()) {
        self.sparse_components.items[kind.decode().sparse].remove(self, idx);
    } else {
        self.dense_components.items[kind.decode().dense].remove(self, idx);
    }
}

pub fn has_component(self: *Self, eid: EId, kind: ComponentKind) bool {
    const decoded = DecodedId.decode(eid);
    if (Options.ecs_logging) {
        Log.log(.debug, "Ecs@{*}: Check if entity {f} has component {f}", .{ self, decoded, kind });
    }
    const e = &self.entities.entities.items[decoded.index.as_index()];
    return e.components.get(self, kind) != null;
}

pub fn get_component(self: *Self, eid: EId, comptime T: type, kind: ComponentKind) ?*T {
    const decoded = DecodedId.decode(eid);
    if (Options.ecs_logging) {
        Log.log(.debug, "Ecs@{*}: get component {f} of entity {f}", .{ self, kind, decoded });
    }
    const e = &self.entities.entities.items[decoded.index.as_index()];
    const store: *ComponentStore = switch (kind.decode()) {
        .reserved => std.debug.panic("Ecs@{*}: access invalid component", .{self}),
        .sparse => |idx| &self.sparse_components.items[idx],
        .dense => |idx| &self.dense_components.items[idx],
    };

    const idx = e.components.get(self, kind) orelse return null;
    const ref = store.get(idx);

    if (Options.ecs_typecheck) {
        if (@typeInfo(T) != store.info.body_type) {
            std.debug.panic("Ecs@{*}: failed to typecheck component {f}, expected {}, got {}", .{
                self,
                kind,
                store.info.body_type,
                std.meta.activeTag(@typeInfo(T)),
            });
        }
        if (ref.parent.* != eid) {
            std.debug.panic("Ecs@{*}: component {f}@{d} parent mismatch: expected {f}, got {f}", .{
                self,
                kind,
                ref.idx,
                DecodedId.decode(ref.parent.*),
                DecodedId.decode(eid),
            });
        }
    }

    return @ptrCast(@alignCast(ref.data));
}

pub fn is_alive(self: *Self, eid: EId) bool {
    const decoded = DecodedId.decode(eid);
    const e = &self.entities.entities.items[decoded.index.as_index()];
    return e.alive and e.eid == eid;
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
    try std.testing.expectEqual(1024, @intFromEnum(pos));
    try std.testing.expectEqual(1025, @intFromEnum(vel));
    try std.testing.expectEqual(1026, @intFromEnum(name));
    try std.testing.expectEqual((1 << 63) + 1, @intFromEnum(player_tag));
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
    try std.testing.expectEqual(DecodedId.decode(zombie).index, DecodedId.decode(player).index);
    try std.testing.expectEqual(
        DecodedId.decode(zombie).generation + 1,
        DecodedId.decode(player).generation,
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
