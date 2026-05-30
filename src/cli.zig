const std = @import("std");

pub const version = "9.0.0";

pub const Flags = struct {
    force: bool = false,
    verbose: bool = false,
    silent: bool = false,
    force_after_timeout_ms: ?u64 = null,
    smart_case: bool = false,
    case_sensitive: bool = false,
};

pub const Action = enum {
    run,
    help,
    version,
};

pub const ParseResult = struct {
    action: Action = .run,
    flags: Flags = .{},
    inputs: []const []const u8 = &.{},
};

pub const ParseError = std.mem.Allocator.Error || error{
    MissingTimeoutValue,
    InvalidTimeoutValue,
    UnknownOption,
};

pub const help_text =
    \\Usage
    \\  $ fkill [<pid|name|:port> …]
    \\
    \\Options
    \\  --force -f                         Force kill
    \\  --verbose -v                       Show process arguments
    \\  --silent -s                        Silently kill and always exit with code 0
    \\  --force-after-timeout <N>, -t <N>  Force kill processes which didn't exit after N seconds
    \\  --smart-case                       Case-insensitive unless pattern contains uppercase
    \\  --case-sensitive                   Force case-sensitive matching
    \\
    \\Examples
    \\  $ fkill 1337
    \\  $ fkill safari
    \\  $ fkill :8080
    \\  $ fkill 1337 safari :8080
    \\  $ fkill
    \\
    \\To kill a port, prefix it with a colon. For example: :8080.
    \\
    \\Run without arguments to use the interactive mode.
    \\In interactive mode, 🚦n% indicates high CPU usage and 🐏n% indicates high memory usage.
    \\Supports fuzzy search in the interactive mode.
    \\
    \\The process name is case-insensitive by default.
    \\
;

pub fn parse(allocator: std.mem.Allocator, argv: []const []const u8) ParseError!ParseResult {
    var result = ParseResult{};
    var inputs: std.ArrayList([]const u8) = .empty;
    errdefer inputs.deinit(allocator);

    var index: usize = 1;
    while (index < argv.len) : (index += 1) {
        const arg = argv[index];

        if (std.mem.eql(u8, arg, "--")) {
            index += 1;
            while (index < argv.len) : (index += 1) {
                try inputs.append(allocator, argv[index]);
            }
            break;
        }

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            result.action = .help;
            continue;
        }

        if (std.mem.eql(u8, arg, "--version")) {
            result.action = .version;
            continue;
        }

        if (std.mem.startsWith(u8, arg, "--force-after-timeout")) {
            const value = if (std.mem.eql(u8, arg, "--force-after-timeout"))
                readFollowingValue(argv, &index) orelse return error.MissingTimeoutValue
            else if (std.mem.startsWith(u8, arg, "--force-after-timeout="))
                arg["--force-after-timeout=".len..]
            else
                return error.UnknownOption;

            result.flags.force_after_timeout_ms = parseSecondsAsMilliseconds(value) orelse return error.InvalidTimeoutValue;
            continue;
        }

        if (std.mem.eql(u8, arg, "--force")) {
            result.flags.force = true;
            continue;
        }

        if (std.mem.eql(u8, arg, "--verbose")) {
            result.flags.verbose = true;
            continue;
        }

        if (std.mem.eql(u8, arg, "--silent")) {
            result.flags.silent = true;
            continue;
        }

        if (std.mem.eql(u8, arg, "--smart-case")) {
            result.flags.smart_case = true;
            continue;
        }

        if (std.mem.eql(u8, arg, "--case-sensitive")) {
            result.flags.case_sensitive = true;
            continue;
        }

        if (std.mem.startsWith(u8, arg, "-") and arg.len > 1) {
            try parseShortFlags(argv, &index, arg, &result.flags);
            continue;
        }

        try inputs.append(allocator, arg);
    }

    result.inputs = try inputs.toOwnedSlice(allocator);
    return result;
}

pub fn shouldIgnoreCase(inputs: []const []const u8, flags: Flags) bool {
    if (flags.case_sensitive) {
        return false;
    }

    if (flags.smart_case) {
        for (inputs) |input| {
            for (input) |byte| {
                if (std.ascii.isUpper(byte)) {
                    return false;
                }
            }
        }
    }

    return true;
}

fn parseShortFlags(argv: []const []const u8, index: *usize, arg: []const u8, flags: *Flags) ParseError!void {
    var short_index: usize = 1;
    while (short_index < arg.len) : (short_index += 1) {
        switch (arg[short_index]) {
            'f' => flags.force = true,
            'v' => flags.verbose = true,
            's' => flags.silent = true,
            't' => {
                const value = if (short_index + 1 < arg.len)
                    arg[short_index + 1 ..]
                else
                    readFollowingValue(argv, index) orelse return error.MissingTimeoutValue;

                flags.force_after_timeout_ms = parseSecondsAsMilliseconds(value) orelse return error.InvalidTimeoutValue;
                return;
            },
            else => return error.UnknownOption,
        }
    }
}

fn readFollowingValue(argv: []const []const u8, index: *usize) ?[]const u8 {
    if (index.* + 1 >= argv.len) {
        return null;
    }

    index.* += 1;
    return argv[index.*];
}

fn parseSecondsAsMilliseconds(value: []const u8) ?u64 {
    if (value.len == 0) {
        return null;
    }

    const seconds = std.fmt.parseFloat(f64, value) catch return null;
    if (!std.math.isFinite(seconds) or seconds < 0) {
        return null;
    }

    return @intFromFloat(seconds * 1000);
}

test "parse flags and inputs" {
    const allocator = std.testing.allocator;
    const parsed = try parse(allocator, &.{ "fkill", "-fs", "-t", "1.5", "--smart-case", "Safari", ":8080" });
    defer allocator.free(parsed.inputs);

    try std.testing.expect(parsed.flags.force);
    try std.testing.expect(parsed.flags.silent);
    try std.testing.expect(parsed.flags.smart_case);
    try std.testing.expectEqual(@as(?u64, 1500), parsed.flags.force_after_timeout_ms);
    try std.testing.expectEqualSlices(u8, "Safari", parsed.inputs[0]);
    try std.testing.expectEqualSlices(u8, ":8080", parsed.inputs[1]);
}

test "case matching modes" {
    try std.testing.expect(shouldIgnoreCase(&.{"safari"}, .{}));
    try std.testing.expect(!shouldIgnoreCase(&.{"safari"}, .{ .case_sensitive = true }));
    try std.testing.expect(shouldIgnoreCase(&.{"safari"}, .{ .smart_case = true }));
    try std.testing.expect(!shouldIgnoreCase(&.{"Safari"}, .{ .smart_case = true }));
}
