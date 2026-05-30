const std = @import("std");
const cli = @import("cli.zig");
const interactive = @import("interactive.zig");
const proc = @import("process.zig");

pub fn run(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !u8 {
    const parsed = cli.parse(allocator, argv) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            try printParseError(io, err);
            return 1;
        },
    };
    defer allocator.free(parsed.inputs);

    switch (parsed.action) {
        .help => {
            var buffer: [4096]u8 = undefined;
            var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &buffer);
            const stdout = &stdout_file_writer.interface;
            try stdout.writeAll(cli.help_text);
            try stdout.flush();
            return 0;
        },
        .version => {
            var buffer: [64]u8 = undefined;
            var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &buffer);
            const stdout = &stdout_file_writer.interface;
            try stdout.print("{s}\n", .{cli.version});
            try stdout.flush();
            return 0;
        },
        .run => {},
    }

    if (parsed.inputs.len == 0) {
        return interactive.init(allocator, io, parsed.flags);
    }

    const ignore_case = cli.shouldIgnoreCase(parsed.inputs, parsed.flags);
    var summary = try proc.killInputs(allocator, io, parsed.inputs, .{
        .force = parsed.flags.force,
        .silent = parsed.flags.silent,
        .force_after_timeout_ms = parsed.flags.force_after_timeout_ms,
        .ignore_case = ignore_case,
    });
    defer summary.deinit(allocator);

    if (parsed.flags.silent) {
        return 0;
    }

    if (summary.errors.items.len == 0) {
        return 0;
    }

    if (parsed.flags.force) {
        printErrors(summary.errors.items);
        return 1;
    }

    if (!(std.Io.File.stdout().isTty(io) catch false)) {
        std.debug.print("Error killing process. Try `fkill --force", .{});
        for (parsed.inputs) |input| {
            std.debug.print(" {s}", .{input});
        }
        std.debug.print("`\n", .{});
        return 1;
    }

    return promptForceAfterError(allocator, io, parsed.inputs, ignore_case);
}

fn printParseError(io: std.Io, err: anyerror) !void {
    _ = io;
    switch (err) {
        error.MissingTimeoutValue => std.debug.print("Expected a value for --force-after-timeout\n", .{}),
        error.InvalidTimeoutValue => std.debug.print("Expected --force-after-timeout to be a number\n", .{}),
        error.UnknownOption => std.debug.print("Unknown option\n", .{}),
        else => std.debug.print("Invalid arguments\n", .{}),
    }
}

fn printErrors(errors: []const []const u8) void {
    for (errors) |message| {
        std.debug.print("{s}\n", .{message});
    }
}

fn promptForceAfterError(allocator: std.mem.Allocator, io: std.Io, inputs: []const []const u8, ignore_case: bool) !u8 {
    var buffer: [256]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &buffer);
    const stdout = &stdout_file_writer.interface;
    try stdout.writeAll("Error killing process. Would you like to use the force? (y/N) ");
    try stdout.flush();

    var answer: [1]u8 = undefined;
    const read = try std.posix.read(std.posix.STDIN_FILENO, &answer);
    try stdout.writeAll("\n");
    try stdout.flush();

    if (read == 1 and (answer[0] == 'y' or answer[0] == 'Y')) {
        var force_summary = try proc.killInputs(allocator, io, inputs, .{
            .force = true,
            .ignore_case = ignore_case,
        });
        defer force_summary.deinit(allocator);

        if (force_summary.errors.items.len == 0) {
            return 0;
        }

        printErrors(force_summary.errors.items);
    }

    return 1;
}

test "help and version are stable" {
    try std.testing.expect(std.mem.indexOf(u8, cli.help_text, "--force-after-timeout") != null);
    try std.testing.expectEqualSlices(u8, "9.0.0", cli.version);
}
