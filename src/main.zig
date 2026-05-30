const std = @import("std");
const fkill = @import("fkill_zig");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const status = fkill.app.run(init.gpa, init.io, args) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => blk: {
            std.debug.print("fkill: {s}\n", .{@errorName(err)});
            break :blk @as(u8, 1);
        },
    };

    std.process.exit(status);
}
