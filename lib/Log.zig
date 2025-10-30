const std = @import("std");

const LogLevel = enum {
    debug,
    info,
    warn,
    err,
    fatal,
};
pub fn log(level: LogLevel, comptime fmt: []const u8, args: anytype) void {
    switch (level) {
        .debug => std.log.debug(fmt, args),
        .info => std.log.info(fmt, args),
        .warn => std.log.warn(fmt, args),
        .err => {
            std.log.err(fmt, args);
            std.debug.dumpCurrentStackTrace(null);
        },
        .fatal => {
            std.log.err(fmt, args);
            std.debug.dumpCurrentStackTrace(null);
            std.process.exit(1);
        },
    }
}
