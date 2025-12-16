const std = @import("std");

const EventManager = @This();
pub const Error = error{
    InvalidEvent,
    EventBodyTypeMismatch,
    EventNameExists,
} || OOM;
const OOM = std.mem.Allocator.Error;

all_events: std.ArrayList(EventData),
named: std.StringArrayHashMapUnmanaged(Event),
events_with_data: std.ArrayList(Event),
gpa: std.mem.Allocator,
callback_data: std.heap.ArenaAllocator,

pub fn init(gpa: std.mem.Allocator) EventManager {
    return .{
        .all_events = .empty,
        .events_with_data = .empty,
        .named = .empty,
        .gpa = gpa,
        .callback_data = .init(gpa),
    };
}

pub fn deinit(self: *EventManager) void {
    for (self.all_events.items) |*evt| {
        evt.bodies.deinit(self.gpa);
        evt.callbacks.deinit(self.gpa);
    }
    self.events_with_data.deinit(self.gpa);
    self.all_events.deinit(self.gpa);
    self.callback_data.deinit();
    self.named.deinit(self.gpa);
}

pub fn register_event(self: *EventManager, comptime Body: type) OOM!Event {
    const Handler = struct {
        fn run(evt_data: *EventData) void {
            const bodies: []const Body = @ptrCast(@alignCast(evt_data.bodies.items));
            for (evt_data.callbacks.items) |cb| {
                const fptr: *const fn (*anyopaque, Body) void = @ptrCast(cb.fptr);
                for (bodies) |b| {
                    fptr(cb.data, b);
                }
            }
        }

        fn append(evt_data: *EventData, gpa: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
            if (evt_data.bodies.capacity == 0) {
                try evt_data.bodies.append(gpa, 0);
                _ = evt_data.bodies.pop();
            }

            const end: usize = @intFromPtr(evt_data.bodies.items.ptr + evt_data.bodies.items.len);
            const next_start = std.mem.Alignment.of(Body).forward(end);
            const next_end = next_start + @sizeOf(Body);
            const size = next_end - end;
            const offset = next_start - end;
            const buf = try evt_data.bodies.addManyAsSlice(gpa, size);
            return buf[offset..];
        }
    };

    const idx = self.all_events.items.len;
    try self.all_events.append(self.gpa, EventData{
        .body_type = type_id(Body),
        .eid = .from_int(idx),
        .callbacks = .empty,
        .bodies = .empty,
        .run = @ptrCast(&Handler.run),
        .append = @ptrCast(&Handler.append),
    });

    return Event.from_int(idx);
}

pub fn name_event(self: *EventManager, evt: Event, name: []const u8) Error!void {
    const entry = try self.named.getOrPut(self.gpa, name);
    if (entry.found_existing) return Error.EventNameExists;
    entry.value_ptr.* = evt;
}

pub fn get_named(self: *EventManager, name: []const u8) ?Event {
    return self.named.get(name);
}

pub fn emit(self: *EventManager, evt: Event, value: anytype) Error!void {
    if (evt == .invalid) return Error.InvalidEvent;

    const event_data = &self.all_events.items[evt.to_int(usize)];
    const Value = @TypeOf(value);
    if (event_data.body_type != type_id(Value)) return Error.EventBodyTypeMismatch;

    if (event_data.bodies.items.len == 0) {
        try self.events_with_data.append(self.gpa, evt);
    }
    const buf = try event_data.append(event_data, self.gpa);
    const raw_val = std.mem.asBytes(&value);
    @memcpy(buf, raw_val);
}

pub fn process(self: *EventManager) void {
    for (self.events_with_data.items) |eid| {
        const evt = &self.all_events.items[eid.to_int(usize)];
        evt.run(evt);
        evt.bodies.clearRetainingCapacity();
    }
    self.events_with_data.clearRetainingCapacity();
}

// func takes parameters of type Args ++ .{ Body} and returns void
pub fn add_listener(
    self: *EventManager,
    evt: Event,
    comptime func: anytype,
    args: anytype,
) Error!EventListenerHandle {
    const Args = @TypeOf(args);
    const Fn = @TypeOf(func);
    const fn_info = @typeInfo(Fn).@"fn";
    const Body = fn_info.params[fn_info.params.len - 1].type.?;

    if (evt == .invalid) return Error.InvalidEvent;
    const event_data = &self.all_events.items[evt.to_int(usize)];
    if (type_id(Body) != event_data.body_type) return Error.EventBodyTypeMismatch;

    const Closure = struct {
        args: Args,

        fn callback(closure: *@This(), body: Body) void {
            @call(.auto, func, closure.args ++ .{body});
        }
    };

    const closure = try self.callback_data.allocator().create(Closure);
    closure.* = Closure{
        .args = args,
    };

    const callback = Callback{
        .data = @ptrCast(closure),
        .fptr = @ptrCast(&Closure.callback),
    };

    try event_data.callbacks.append(self.gpa, callback);
    return .{
        .evt = evt,
        .idx = event_data.callbacks.items.len - 1,
    };
}

pub const Event = enum(usize) {
    const OFFSET = 1;
    invalid = 0,

    _,

    fn to_int(self: Event, comptime Int: type) Int {
        return @intFromEnum(self) - OFFSET;
    }

    fn from_int(int: anytype) Event {
        return @enumFromInt(int + OFFSET);
    }
};

pub const EventListenerHandle = struct {
    evt: Event,
    idx: usize,
};

const Callback = struct {
    data: *anyopaque,
    fptr: *const anyopaque,
};

const EventData = struct {
    body_type: usize,
    eid: Event,
    callbacks: std.ArrayList(Callback),
    bodies: std.ArrayList(u8),
    run: *const fn (self: *EventData) void,
    append: *const fn (self: *EventData, gpa: std.mem.Allocator) std.mem.Allocator.Error![]u8,
};

fn type_id(comptime T: type) usize {
    const H = struct {
        var instance: T = undefined;
    };
    return @intFromPtr(&H.instance);
}

test type_id {
    try std.testing.expectEqual(type_id(u32), type_id(u32));
    try std.testing.expect(type_id(u32) != type_id(i32));
}

test {
    var events = EventManager.init(std.testing.allocator);
    defer events.deinit();

    const e1 = try events.register_event(u32);
    const e2 = try events.register_event([]const u8);

    const Handler = struct {
        got_u32: u32 = 69,
        got_str: []const u8 = "default",

        const Handler = @This();
        fn on_e1(self: *Handler, val: u32) void {
            self.got_u32 = val;
        }

        fn on_e2(self: *Handler, val: []const u8) void {
            self.got_str = val;
        }

        fn on_e3(self: *Handler, val: usize) void {
            std.debug.panic("{*}: Should be unreachable: {}", .{ self, val });
        }
    };

    var handler = Handler{};

    _ = try events.add_listener(e1, Handler.on_e1, .{&handler});
    _ = try events.add_listener(e2, Handler.on_e2, .{&handler});
    try std.testing.expectError(
        Error.EventBodyTypeMismatch,
        events.add_listener(e1, Handler.on_e3, .{&handler}),
    );

    events.process();
    try std.testing.expectEqual(69, handler.got_u32);
    try std.testing.expectEqualStrings("default", handler.got_str);

    try events.emit(e1, @as(u32, 420));
    try events.emit(e1, @as(u32, 1337));
    try events.emit(e2, @as([]const u8, "hello world"));
    try std.testing.expectError(Error.EventBodyTypeMismatch, events.emit(e1, @as(usize, 69)));

    events.process();
    try std.testing.expectEqual(1337, handler.got_u32);
    try std.testing.expectEqualStrings("hello world", handler.got_str);

    events.process();
    try std.testing.expectEqual(1337, handler.got_u32);
    try std.testing.expectEqualStrings("hello world", handler.got_str);
}

test "Multi arg" {
    var events = EventManager.init(std.testing.allocator);
    defer events.deinit();
    const evt = try events.register_event(u32);

    const Handler = struct {
        fn callback(x: *u32, y: u32, z: u32) void {
            x.* += y * z;
        }
    };

    var res: u32 = 0;
    _ = try events.add_listener(evt, Handler.callback, .{ &res, 69 });

    try events.emit(evt, @as(u32, 1));
    try events.emit(evt, @as(u32, 100));
    try events.emit(evt, @as(u32, 10000));

    events.process();
    try std.testing.expectEqual(696969, res);
}
