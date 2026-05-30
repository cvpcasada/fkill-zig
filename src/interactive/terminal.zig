const std = @import("std");

pub const RawMode = struct {
    original: std.posix.termios,
    active: bool = true,

    pub fn enable() !RawMode {
        const original = try std.posix.tcgetattr(std.posix.STDIN_FILENO);
        var raw = original;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.cc[@intFromEnum(std.c.V.MIN)] = 1;
        raw.cc[@intFromEnum(std.c.V.TIME)] = 0;
        try std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, raw);
        return .{ .original = original };
    }

    pub fn restore(self: *RawMode) void {
        if (!self.active) return;

        std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, self.original) catch {};
        self.active = false;
    }
};

pub fn width() usize {
    var size: std.posix.winsize = undefined;
    if (std.c.ioctl(std.posix.STDOUT_FILENO, @intCast(std.c.T.IOCGWINSZ), &size) == 0 and size.col > 0) {
        return size.col;
    }

    return 80;
}

pub fn height() usize {
    var size: std.posix.winsize = undefined;
    if (std.c.ioctl(std.posix.STDOUT_FILENO, @intCast(std.c.T.IOCGWINSZ), &size) == 0 and size.row > 0) {
        return size.row;
    }

    return 24;
}
