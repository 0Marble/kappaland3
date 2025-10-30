const std = @import("std");
const Options = @import("Options");
const Log = @import("Log.zig");

pub const EId = u64;

pub fn Ecs(comptime Component: type) type {
    const Tag = std.meta.Tag;
    const ref_fields = comptime blk: {
        const tags = std.meta.fieldNames(Component);
        var ref_fields: [tags.len]std.builtin.Type.UnionField = undefined;
        for (tags, &ref_fields) |tag_name, *field| {
            const typ = *@FieldType(Component, tag_name);
            field.* = .{
                .type = typ,
                .alignment = @alignOf(typ),
                .name = tag_name,
            };
        }

        break :blk ref_fields;
    };

    return struct {
        const Self = @This();
        const ComponentRef = @Type(std.builtin.Type{ .@"union" = .{
            .decls = &.{},
            .fields = &ref_fields,
            .layout = .auto,
            .tag_type = Tag(Component),
        } });

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
                try writer.print("EId{}@{}", .{ self.index, self.generation });
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

        const Entity = struct {
            eid: EId,
            components: ComponentSet,
            free: bool,

            pub fn has_component(self: *Entity, kind: Tag(Component)) bool {
                return self.components.has(kind);
            }
        };

        const ComponentSet = struct {
            set: std.EnumMap(Tag(Component), usize),

            pub const empty: ComponentSet = .{
                .set = .init(.{}),
            };

            pub fn add(self: *ComponentSet, gpa: std.mem.Allocator, kind: Tag(Component), index: usize) !void {
                _ = gpa;
                self.set.put(kind, index);
            }

            pub fn has(self: *ComponentSet, kind: Tag(Component)) bool {
                return self.set.get(kind) != null;
            }

            pub fn get(self: *ComponentSet, kind: Tag(Component)) ?usize {
                return self.set.get(kind);
            }

            pub fn remove(self: *ComponentSet, kind: Tag(Component)) void {
                self.set.remove(kind);
            }

            pub fn deinit(self: *ComponentSet) void {
                _ = self;
            }

            pub fn clear(self: *ComponentSet) void {
                inline for (std.meta.tags(Tag(Component))) |tag| {
                    self.set.remove(tag);
                }
            }

            const Iter = @FieldType(ComponentSet, "set").Iterator;
            pub fn iterate(self: *ComponentSet) Iter {
                return self.set.iterator();
            }
        };

        const ComponentsStore = struct {
            fn Entry(comptime kind: Tag(Component)) type {
                return struct {
                    parent: EId,
                    index: usize,
                    value: @FieldType(Component, @tagName(kind)),
                };
            }
            const List = struct {
                data: std.ArrayListAlignedUnmanaged(u8, .fromByteUnits(@alignOf(Component))),
                free: std.ArrayListUnmanaged(usize),
                kind: Tag(Component),
            };

            lists: [std.meta.fieldNames(Component).len]List,

            fn empty() ComponentsStore {
                var self = ComponentsStore{
                    .lists = std.mem.zeroes(@FieldType(ComponentsStore, "lists")),
                };
                inline for (std.meta.tags(Tag(Component)), 0..) |tag, i| {
                    self.lists[i].kind = tag;
                    self.lists[i].free = .empty;
                    self.lists[i].data = .empty;
                }

                return self;
            }

            fn of_type(self: *ComponentsStore, comptime kind: Tag(Component)) []Entry(kind) {
                return @ptrCast(self.lists[@intFromEnum(kind)].data.items);
            }

            fn get(self: *ComponentsStore, comptime kind: Tag(Component), idx: usize) *Entry(kind) {
                return &self.of_type(kind)[idx];
            }

            fn push(self: *ComponentsStore, gpa: std.mem.Allocator, comptime kind: Tag(Component)) !*Entry(kind) {
                const list = &self.lists[@intFromEnum(kind)];
                const idx = if (list.free.pop()) |old| blk: {
                    break :blk old;
                } else blk: {
                    const new = self.of_type(kind).len;
                    _ = try list.data.addManyAsArray(gpa, @sizeOf(Entry(kind)));
                    break :blk new;
                };
                const entry: *Entry(kind) = &self.of_type(kind)[idx];
                entry.index = idx;
                entry.parent = DecodedId.empty.encode();
                return entry;
            }

            fn remove(self: *ComponentsStore, gpa: std.mem.Allocator, comptime kind: Tag(Component), idx: usize) !void {
                try self.lists[@intFromEnum(kind)].free.append(gpa, idx);
            }
        };

        gpa: std.mem.Allocator,
        entities: std.ArrayListUnmanaged(Entity),
        free_entities: std.ArrayListUnmanaged(EId),
        components: ComponentsStore,

        pub fn init(gpa: std.mem.Allocator) Self {
            return .{
                .gpa = gpa,
                .entities = .empty,
                .free_entities = .empty,
                .components = .empty(),
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.entities.items) |*e| {
                e.components.deinit();
            }
            self.entities.deinit(self.gpa);
            self.free_entities.deinit(self.gpa);
            for (&self.components.lists) |*list| {
                list.free.deinit(self.gpa);
                list.data.deinit(self.gpa);
            }
        }

        pub fn spawn(self: *Self) !EId {
            if (self.free_entities.pop()) |old_id| {
                const decoded = DecodedId.decode(old_id).increment_generation();
                const idx = decoded.index.as_index();
                const eid = decoded.encode();
                const e = &self.entities.items[idx];
                e.eid = eid;
                e.free = false;
                if (Options.ecs_logging) {
                    Log.log(.debug, @typeName(Self) ++ " spawn: reusing {f}", .{decoded});
                }
                return eid;
            } else {
                const decoded = DecodedId.from_parts(DecodedId.Index.from_index(self.entities.items.len), 0);
                const eid = decoded.encode();
                const e = Entity{
                    .eid = eid,
                    .components = ComponentSet.empty,
                    .free = false,
                };
                if (Options.ecs_logging) {
                    Log.log(.debug, @typeName(Self) ++ " spawn: new {f}", .{decoded});
                }
                _ = try self.entities.append(self.gpa, e);
                return eid;
            }
        }

        pub fn kill(self: *Self, eid: EId) !void {
            var it = self.iterate_components(eid);
            while (it.next()) |component| {
                try self.remove_component(eid, @as(Tag(Component), component));
            }
            if (Options.ecs_logging) {
                Log.log(.debug, @typeName(Self) ++ " kill: {f}", .{DecodedId.decode(eid)});
            }
            const idx = DecodedId.decode(eid).index.as_index();
            const e = &self.entities.items[idx];
            e.components.clear();
            e.free = true;
            e.eid = DecodedId.empty.encode();
            try self.free_entities.append(self.gpa, eid);
        }

        pub fn get_component(
            self: *Self,
            eid: EId,
            comptime kind: Tag(Component),
        ) ?*@FieldType(Component, @tagName(kind)) {
            const e = &self.entities.items[DecodedId.decode(eid).index.as_index()];
            const idx = e.components.get(kind) orelse return null;
            const entry = self.components.get(kind, idx);
            return &entry.value;
        }

        pub fn get_component_any(self: *Self, eid: EId, kind: Tag(Component)) ?ComponentRef {
            switch (kind) {
                inline else => |tag| {
                    const concrete = self.get_component(eid, tag) orelse return null;
                    return @unionInit(ComponentRef, @tagName(tag), concrete);
                },
            }
        }

        pub fn add_component(self: *Self, eid: EId, component: Component) !void {
            switch (@as(Tag(Component), component)) {
                inline else => |tag| {
                    const entry = try self.components.push(self.gpa, tag);
                    entry.parent = eid;
                    entry.value = @field(component, @tagName(tag));
                    const e = &self.entities.items[DecodedId.decode(eid).index.as_index()];
                    try e.components.add(self.gpa, tag, entry.index);
                    if (Options.ecs_logging) {
                        Log.log(.debug, @typeName(Self) ++ " add_component: {f} got component {s}#{d}", .{
                            DecodedId.decode(eid),
                            @tagName(tag),
                            entry.index,
                        });
                    }
                },
            }
        }

        pub fn remove_component(self: *Self, eid: EId, kind: Tag(Component)) !void {
            switch (kind) {
                inline else => |tag| {
                    const e = &self.entities.items[DecodedId.decode(eid).index.as_index()];
                    const idx = e.components.get(tag).?;
                    e.components.remove(tag);
                    try self.components.remove(self.gpa, tag, idx);
                    if (Options.ecs_logging) {
                        Log.log(.debug, @typeName(Self) ++ " remove_component: {f} {s}", .{
                            DecodedId.decode(eid),
                            @tagName(tag),
                        });
                    }
                },
            }
        }

        pub fn has_component(self: *Self, eid: EId, kind: Tag(Component)) bool {
            const e = &self.entities.items[DecodedId.decode(eid).index.as_index()];
            return e.has_component(kind);
        }

        const ComponentIter = struct {
            ecs: *Self,
            eid: EId,
            inner: ComponentSet.Iter,

            pub fn next(self: *ComponentIter) ?ComponentRef {
                const entry = self.inner.next() orelse return null;
                return self.ecs.get_component_any(self.eid, entry.key).?;
            }
        };

        pub fn iterate_components(self: *Self, eid: EId) ComponentIter {
            const e = &self.entities.items[DecodedId.decode(eid).index.as_index()];
            return .{ .ecs = self, .eid = eid, .inner = e.components.iterate() };
        }

        pub fn query(
            self: *Self,
            comptime components: []const Tag(Component),
            ctx: anytype,
            system: *const fn (ctx: @TypeOf(ctx), ecs: *Self, eid: EId) void,
        ) void {
            if (components.len == 0) {
                for (self.entities.items) |e| {
                    if (!e.free) system(ctx, self, e.eid);
                }
            } else {
                var initial_idx: usize = 0;
                inline for (components, 0..) |tag, i| {
                    const a = self.components.of_type(components[initial_idx]).len;
                    const b = self.components.of_type(tag).len;
                    if (a > b) {
                        initial_idx = i;
                    }
                }
                const initial = self.components.of_type(components[initial_idx]);
                outer: for (initial) |entry| {
                    const parent: *Entity = &self.entities.items[DecodedId.decode(entry.parent).index.as_index()];
                    inline for (components) |kind| if (!parent.has_component(kind)) continue :outer;
                    system(ctx, self, .{ .eid = entry.parent });
                }
            }
        }
    };
}

const TestComponents = union(enum) {
    position: @Vector(2, f32),
    speed: @Vector(2, f32),
    name: []const u8,
    player_tag: void,
};

test "creation" {
    var ecs = Ecs(TestComponents).init(std.testing.allocator);
    defer ecs.deinit();
}

test "spawn/kill" {
    const EcsType = Ecs(TestComponents);
    var ecs = EcsType.init(std.testing.allocator);
    defer ecs.deinit();

    const player = try ecs.spawn();
    const player_id = EcsType.DecodedId.decode(player);
    try std.testing.expectEqual(0, player_id.index.as_index());
    try std.testing.expectEqual(0, player_id.generation);
    try ecs.kill(player);

    const zombie = try ecs.spawn();
    const zombie_id = EcsType.DecodedId.decode(zombie);
    try std.testing.expectEqual(0, zombie_id.index.as_index());
    try std.testing.expectEqual(1, zombie_id.generation);
    try ecs.kill(zombie);
}

test "add components" {
    const EcsType = Ecs(TestComponents);
    var ecs = EcsType.init(std.testing.allocator);
    defer ecs.deinit();

    const player = try ecs.spawn();
    try ecs.add_component(player, .{ .player_tag = {} });
    try ecs.add_component(player, .{ .name = "Player" });
    try std.testing.expect(ecs.has_component(player, .player_tag));
    try std.testing.expect(ecs.has_component(player, .name));
    try std.testing.expect(!ecs.has_component(player, .position));

    const zombie = try ecs.spawn();
    try ecs.add_component(zombie, .{ .name = "Zombie" });
    try std.testing.expect(!ecs.has_component(zombie, .player_tag));
    try std.testing.expect(ecs.has_component(zombie, .name));
    try std.testing.expect(!ecs.has_component(zombie, .position));
}

test "add and remove components" {
    const EcsType = Ecs(TestComponents);
    var ecs = EcsType.init(std.testing.allocator);
    defer ecs.deinit();

    const player = try ecs.spawn();
    try ecs.add_component(player, .{ .player_tag = {} });
    try ecs.add_component(player, .{ .name = "Player" });
    try ecs.remove_component(player, .name);
    try std.testing.expect(!ecs.has_component(player, .name));
    try ecs.add_component(player, .{ .name = "Alex" });
    try std.testing.expect(ecs.has_component(player, .name));
}

test "access component" {
    const EcsType = Ecs(TestComponents);
    var ecs = EcsType.init(std.testing.allocator);
    defer ecs.deinit();

    const player = try ecs.spawn();
    try ecs.add_component(player, .{ .player_tag = {} });
    try ecs.add_component(player, .{ .name = "Player" });
    const name = ecs.get_component(player, .name).?;
    try std.testing.expectEqualStrings("Player", name.*);
    name.* = "Gamer";
    try std.testing.expectEqualStrings("Gamer", ecs.get_component(player, .name).?.*);
}

test "empty query" {
    const EcsType = Ecs(TestComponents);
    var ecs = EcsType.init(std.testing.allocator);
    defer ecs.deinit();

    const player = try ecs.spawn();
    try ecs.add_component(player, .{ .player_tag = {} });
    try ecs.add_component(player, .{ .name = "Player" });
    const dead = try ecs.spawn();
    try ecs.add_component(dead, .{ .name = "Dead" });
    try ecs.kill(dead);

    const MySystem = struct {
        player_eid: EId,
        dead_eid: EId,
        had_player: bool = false,
        fail: bool = false,

        pub fn run(self: *@This(), _: *EcsType, e: EId) void {
            if (e == self.player_eid) {
                if (self.had_player) {
                    self.fail = true;
                }
                self.had_player = true;
            }
            if (e == self.dead_eid) {
                self.fail = true;
            }
        }
    };
    var sys = MySystem{ .player_eid = player, .dead_eid = dead };

    ecs.query(&.{}, &sys, MySystem.run);
    try std.testing.expect(!sys.fail);
    try std.testing.expect(sys.had_player);
}
