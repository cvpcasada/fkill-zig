const std = @import("std");
const cli = @import("cli.zig");

const max_command_output = 64 * 1024 * 1024;
const default_exit_timeout_ms = 3000;
const alive_check_min_interval_ms = 5;
const alive_check_max_interval_ms = 1280;

pub const ProcessInfo = struct {
    pid: i32,
    ppid: i32,
    uid: u32,
    cpu: f64,
    memory: f64,
    name: []u8,
    cmd: []u8,
    ports: std.ArrayList(u16) = .empty,

    pub fn deinit(self: *ProcessInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.cmd);
        self.ports.deinit(allocator);
    }
};

pub const PortBinding = struct {
    port: u16,
    pid: i32,
};

pub const KillOptions = struct {
    force: bool = false,
    silent: bool = false,
    force_after_timeout_ms: ?u64 = null,
    ignore_case: bool = true,
};

pub const KillSummary = struct {
    errors: std.ArrayList([]u8) = .empty,

    pub fn deinit(self: *KillSummary, allocator: std.mem.Allocator) void {
        for (self.errors.items) |message| {
            allocator.free(message);
        }
        self.errors.deinit(allocator);
    }
};

const KillTarget = struct {
    pid: i32,
    input: []const u8,
};

pub fn listProcesses(allocator: std.mem.Allocator, io: std.Io, all_users: bool) !std.ArrayList(ProcessInfo) {
    const flags = if (all_users) "axwwxo" else "xwwxo";
    const process_result = try runCapture(allocator, io, &.{ "ps", flags, "pid=,ppid=,uid=,pcpu=,pmem=,comm=" }, true);
    defer allocator.free(process_result);
    const command_result = try runCapture(allocator, io, &.{ "ps", flags, "pid=,args=" }, true);
    defer allocator.free(command_result);

    var commands = std.AutoHashMap(i32, []u8).init(allocator);
    defer {
        var iterator = commands.valueIterator();
        while (iterator.next()) |cmd| {
            allocator.free(cmd.*);
        }
        commands.deinit();
    }

    var command_lines = std.mem.splitScalar(u8, command_result, '\n');
    while (command_lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) {
            continue;
        }

        if (firstTokenAndRest(trimmed)) |parts| {
            const pid = std.fmt.parseInt(i32, parts.first, 10) catch continue;
            try commands.put(pid, try allocator.dupe(u8, parts.rest));
        }
    }

    var processes: std.ArrayList(ProcessInfo) = .empty;
    errdefer deinitProcesses(&processes, allocator);

    var process_lines = std.mem.splitScalar(u8, process_result, '\n');
    while (process_lines.next()) |line| {
        const parsed = parsePsProcessLine(line) orelse continue;
        const command = commands.get(parsed.pid) orelse "";

        try processes.append(allocator, .{
            .pid = parsed.pid,
            .ppid = parsed.ppid,
            .uid = parsed.uid,
            .cpu = parsed.cpu,
            .memory = parsed.memory,
            .name = try deriveProcessName(allocator, parsed.comm, command),
            .cmd = try allocator.dupe(u8, command),
        });
    }

    return processes;
}

pub fn addPortsToProcesses(allocator: std.mem.Allocator, io: std.Io, processes: *std.ArrayList(ProcessInfo)) !void {
    var bindings = try allPortsWithPid(allocator, io);
    defer bindings.deinit(allocator);

    for (processes.items) |*process_info| {
        for (bindings.items) |binding| {
            if (binding.pid == process_info.pid and !hasPort(process_info.ports.items, binding.port)) {
                try process_info.ports.append(allocator, binding.port);
            }
        }
        std.mem.sort(u16, process_info.ports.items, {}, std.sort.asc(u16));
    }
}

pub fn deinitProcesses(processes: *std.ArrayList(ProcessInfo), allocator: std.mem.Allocator) void {
    for (processes.items) |*process_info| {
        process_info.deinit(allocator);
    }
    processes.deinit(allocator);
}

pub fn killInputs(
    allocator: std.mem.Allocator,
    io: std.Io,
    inputs: []const []const u8,
    options: KillOptions,
) !KillSummary {
    var summary = KillSummary{};
    errdefer summary.deinit(allocator);

    var targets = try resolveKillTargets(allocator, io, inputs, options.ignore_case, &summary);
    defer targets.deinit(allocator);

    var signaled_pids = try signalKillTargets(allocator, targets.items, if (options.force) .KILL else .TERM, &summary);
    defer signaled_pids.deinit(allocator);

    if (options.force_after_timeout_ms) |timeout_ms| {
        var survivors = try waitForExit(allocator, signaled_pids.items, timeout_ms);
        defer survivors.deinit(allocator);
        for (survivors.items) |pid| {
            std.posix.kill(pid, .KILL) catch {};
        }
    }

    return summary;
}

fn resolveKillTargets(
    allocator: std.mem.Allocator,
    io: std.Io,
    inputs: []const []const u8,
    ignore_case: bool,
    summary: *KillSummary,
) !std.ArrayList(KillTarget) {
    var targets: std.ArrayList(KillTarget) = .empty;
    errdefer targets.deinit(allocator);

    const current_pid = std.c.getpid();
    for (inputs) |input| {
        var pids = try resolveInputToPids(allocator, io, input, ignore_case);
        defer pids.deinit(allocator);

        if (pids.items.len == 0) {
            try appendKillError(allocator, summary, input, error.ProcessNotFound);
            continue;
        }

        for (pids.items) |pid| {
            if (pid == current_pid or targetIndex(targets.items, pid) != null) {
                continue;
            }

            try targets.append(allocator, .{ .pid = pid, .input = input });
        }
    }

    return targets;
}

fn signalKillTargets(
    allocator: std.mem.Allocator,
    targets: []const KillTarget,
    signal: std.posix.SIG,
    summary: *KillSummary,
) !std.ArrayList(i32) {
    var signaled_pids: std.ArrayList(i32) = .empty;
    errdefer signaled_pids.deinit(allocator);

    for (targets) |target| {
        std.posix.kill(target.pid, signal) catch |err| {
            try appendKillError(allocator, summary, target.input, err);
            continue;
        };

        try signaled_pids.append(allocator, target.pid);
    }

    return signaled_pids;
}

fn appendKillError(allocator: std.mem.Allocator, summary: *KillSummary, input: []const u8, err: anyerror) !void {
    const message = switch (err) {
        error.ProcessNotFound => try std.fmt.allocPrint(allocator, "Killing process {s} failed: Process doesn't exist", .{input}),
        error.PermissionDenied => try std.fmt.allocPrint(allocator, "Killing process {s} failed: Operation not permitted", .{input}),
        else => try std.fmt.allocPrint(allocator, "Killing process {s} failed: {s}", .{ input, @errorName(err) }),
    };
    try summary.errors.append(allocator, message);
}

pub fn processExists(pid: i32) bool {
    std.posix.kill(pid, @enumFromInt(0)) catch |err| return switch (err) {
        error.ProcessNotFound => false,
        else => true,
    };
    return true;
}

pub fn waitForExit(allocator: std.mem.Allocator, pids: []const i32, timeout_ms: u64) !std.ArrayList(i32) {
    var survivors: std.ArrayList(i32) = .empty;
    if (pids.len == 0) {
        return survivors;
    }

    var interval_ms: u64 = @min(alive_check_min_interval_ms, timeout_ms);
    var elapsed_ms: u64 = 0;

    while (true) {
        survivors.clearRetainingCapacity();
        for (pids) |pid| {
            if (processExists(pid)) {
                try survivors.append(allocator, pid);
            }
        }

        if (survivors.items.len == 0 or elapsed_ms >= timeout_ms) {
            return survivors;
        }

        sleepMs(interval_ms);
        elapsed_ms += interval_ms;
        interval_ms = @min(interval_ms * 2, alive_check_max_interval_ms);
    }
}

pub fn attemptInteractiveKill(allocator: std.mem.Allocator, io: std.Io, pid: i32) !KillSummary {
    const pid_text = try std.fmt.allocPrint(allocator, "{d}", .{pid});
    defer allocator.free(pid_text);

    var summary = try killInputs(allocator, io, &.{pid_text}, .{});
    errdefer summary.deinit(allocator);
    var survivors = try waitForExit(allocator, &.{pid}, default_exit_timeout_ms);
    defer survivors.deinit(allocator);

    if (summary.errors.items.len == 0 and survivors.items.len > 0) {
        try summary.errors.append(allocator, try std.fmt.allocPrint(allocator, "Process didn't exit in {d}ms.", .{default_exit_timeout_ms}));
    }

    return summary;
}

fn resolveInputToPids(allocator: std.mem.Allocator, io: std.Io, input: []const u8, ignore_case: bool) !std.ArrayList(i32) {
    var pids: std.ArrayList(i32) = .empty;
    errdefer pids.deinit(allocator);

    if (std.mem.startsWith(u8, input, ":")) {
        const port = std.fmt.parseInt(u16, input[1..], 10) catch return pids;
        if (try pidForPort(allocator, io, port)) |pid| {
            try pids.append(allocator, pid);
        }
        return pids;
    }

    if (parsePidInput(input)) |pid| {
        if (processExists(pid)) {
            try pids.append(allocator, pid);
        }
        return pids;
    }

    var processes = try listProcesses(allocator, io, true);
    defer deinitProcesses(&processes, allocator);

    for (processes.items) |process_info| {
        const matches = if (ignore_case)
            std.ascii.eqlIgnoreCase(process_info.name, input)
        else
            std.mem.eql(u8, process_info.name, input);

        if (matches) {
            try pids.append(allocator, process_info.pid);
        }
    }

    return pids;
}

pub fn pidForPort(allocator: std.mem.Allocator, io: std.Io, port: u16) !?i32 {
    const port_filter = try std.fmt.allocPrint(allocator, ":{d}", .{port});
    defer allocator.free(port_filter);

    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "lsof", "-nP", "-i", port_filter },
        .stdout_limit = .limited(max_command_output),
        .stderr_limit = .limited(max_command_output),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term != .exited or result.term.exited != 0) {
        return null;
    }

    var fallback_pid: ?i32 = null;
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        const parsed = parseLsofLine(line) orelse continue;
        if (parsed.port != port) {
            continue;
        }

        if (std.mem.indexOf(u8, line, "(LISTEN)") != null) {
            return parsed.pid;
        }

        fallback_pid = parsed.pid;
    }

    return fallback_pid;
}

pub fn allPortsWithPid(allocator: std.mem.Allocator, io: std.Io) !std.ArrayList(PortBinding) {
    var bindings: std.ArrayList(PortBinding) = .empty;
    errdefer bindings.deinit(allocator);

    const result = std.process.run(allocator, io, .{
        .argv = &.{ "lsof", "-nP", "-i" },
        .stdout_limit = .limited(max_command_output),
        .stderr_limit = .limited(max_command_output),
    }) catch return bindings;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term != .exited or result.term.exited != 0) {
        return bindings;
    }

    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        const parsed = parseLsofLine(line) orelse continue;
        if (hasPortPid(bindings.items, parsed.port, parsed.pid)) {
            continue;
        }
        try bindings.append(allocator, parsed);
    }

    return bindings;
}

const TokenParts = struct {
    first: []const u8,
    rest: []const u8,
};

fn firstTokenAndRest(line: []const u8) ?TokenParts {
    var index: usize = 0;
    while (index < line.len and (line[index] == ' ' or line[index] == '\t')) : (index += 1) {}
    const first_start = index;
    while (index < line.len and line[index] != ' ' and line[index] != '\t') : (index += 1) {}
    if (first_start == index) {
        return null;
    }

    const first_end = index;
    while (index < line.len and (line[index] == ' ' or line[index] == '\t')) : (index += 1) {}
    return .{ .first = line[first_start..first_end], .rest = line[index..] };
}

const PsLine = struct {
    pid: i32,
    ppid: i32,
    uid: u32,
    cpu: f64,
    memory: f64,
    comm: []const u8,
};

fn parsePsProcessLine(line: []const u8) ?PsLine {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    var offset: usize = 0;
    const pid_text = nextToken(trimmed, &offset) orelse return null;
    const ppid_text = nextToken(trimmed, &offset) orelse return null;
    const uid_text = nextToken(trimmed, &offset) orelse return null;
    const cpu_text = nextToken(trimmed, &offset) orelse return null;
    const memory_text = nextToken(trimmed, &offset) orelse return null;
    const comm = std.mem.trim(u8, trimmed[offset..], " \t\r");

    if (comm.len == 0) {
        return null;
    }

    return .{
        .pid = std.fmt.parseInt(i32, pid_text, 10) catch return null,
        .ppid = std.fmt.parseInt(i32, ppid_text, 10) catch return null,
        .uid = std.fmt.parseInt(u32, uid_text, 10) catch return null,
        .cpu = std.fmt.parseFloat(f64, cpu_text) catch 0,
        .memory = std.fmt.parseFloat(f64, memory_text) catch 0,
        .comm = comm,
    };
}

fn nextToken(line: []const u8, offset: *usize) ?[]const u8 {
    while (offset.* < line.len and (line[offset.*] == ' ' or line[offset.*] == '\t')) : (offset.* += 1) {}
    const start = offset.*;
    while (offset.* < line.len and line[offset.*] != ' ' and line[offset.*] != '\t') : (offset.* += 1) {}
    if (start == offset.*) {
        return null;
    }
    return line[start..offset.*];
}

fn deriveProcessName(allocator: std.mem.Allocator, comm: []const u8, command: []const u8) ![]u8 {
    const source = if (comm.len > 0) comm else blk: {
        var offset: usize = 0;
        break :blk nextToken(command, &offset) orelse "";
    };

    if (std.mem.lastIndexOfScalar(u8, source, '/')) |index| {
        if (index + 1 < source.len) {
            return allocator.dupe(u8, source[index + 1 ..]);
        }
    }

    return allocator.dupe(u8, source);
}

fn runCapture(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8, require_success: bool) ![]u8 {
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(max_command_output),
        .stderr_limit = .limited(max_command_output),
    });
    errdefer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (require_success and (result.term != .exited or result.term.exited != 0)) {
        return error.CommandFailed;
    }

    return result.stdout;
}

fn parsePidInput(input: []const u8) ?i32 {
    if (input.len == 0) {
        return null;
    }

    for (input) |byte| {
        if (!std.ascii.isDigit(byte)) {
            return null;
        }
    }

    return std.fmt.parseInt(i32, input, 10) catch null;
}

fn parseLsofLine(line: []const u8) ?PortBinding {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "COMMAND")) {
        return null;
    }

    var offset: usize = 0;
    _ = nextToken(trimmed, &offset) orelse return null;
    const pid_text = nextToken(trimmed, &offset) orelse return null;
    const pid = std.fmt.parseInt(i32, pid_text, 10) catch return null;
    const port = extractFirstAddressPort(trimmed) orelse return null;

    return .{ .port = port, .pid = pid };
}

fn extractFirstAddressPort(line: []const u8) ?u16 {
    var index: usize = 0;
    while (index < line.len) : (index += 1) {
        if (line[index] != ':' and line[index] != '.') {
            continue;
        }

        var digit_index = index + 1;
        while (digit_index < line.len and std.ascii.isDigit(line[digit_index])) : (digit_index += 1) {}
        if (digit_index == index + 1) {
            continue;
        }

        if (digit_index < line.len and line[digit_index] != ' ' and line[digit_index] != ')' and line[digit_index] != '-' and line[digit_index] != '\t') {
            continue;
        }

        return std.fmt.parseInt(u16, line[index + 1 .. digit_index], 10) catch null;
    }

    return null;
}

fn targetIndex(targets: []const KillTarget, pid: i32) ?usize {
    for (targets, 0..) |target, index| {
        if (target.pid == pid) return index;
    }
    return null;
}

fn hasPort(ports: []const u16, port: u16) bool {
    for (ports) |existing| {
        if (existing == port) {
            return true;
        }
    }
    return false;
}

fn hasPortPid(bindings: []const PortBinding, port: u16, pid: i32) bool {
    for (bindings) |binding| {
        if (binding.port == port and binding.pid == pid) {
            return true;
        }
    }
    return false;
}

fn sleepMs(milliseconds: u64) void {
    var remaining = std.posix.timespec{
        .sec = @intCast(milliseconds / 1000),
        .nsec = @intCast((milliseconds % 1000) * std.time.ns_per_ms),
    };

    while (std.posix.errno(std.posix.system.nanosleep(&remaining, &remaining)) == .INTR) {}
}

test "parse process list line" {
    const parsed = parsePsProcessLine("123 1 501 4.2 1.5 /Applications/Test App.app/Contents/MacOS/Test App") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(i32, 123), parsed.pid);
    try std.testing.expectEqual(@as(i32, 1), parsed.ppid);
    try std.testing.expectEqual(@as(u32, 501), parsed.uid);
    try std.testing.expectEqual(@as(f64, 4.2), parsed.cpu);
    try std.testing.expectEqualSlices(u8, "/Applications/Test App.app/Contents/MacOS/Test App", parsed.comm);
}

test "split first token and rest" {
    const parts = firstTokenAndRest("123   /usr/bin/node app.js") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualSlices(u8, "123", parts.first);
    try std.testing.expectEqualSlices(u8, "/usr/bin/node app.js", parts.rest);
}

test "parse lsof line" {
    const parsed = parseLsofLine("node 12345 cyrus 25u IPv6 0x123 0t0 TCP *:5173 (LISTEN)") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(i32, 12345), parsed.pid);
    try std.testing.expectEqual(@as(u16, 5173), parsed.port);
}

test "find pid for listening port" {
    const fd = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
    if (fd < 0) return error.SkipZigTest;
    defer _ = std.c.close(fd);

    var address = std.c.sockaddr.in{
        .port = std.mem.nativeToBig(u16, 0),
        .addr = std.mem.nativeToBig(u32, 0x7f000001),
    };

    if (std.c.bind(fd, @ptrCast(&address), @sizeOf(std.c.sockaddr.in)) != 0) {
        return error.SkipZigTest;
    }

    if (std.c.listen(fd, 1) != 0) {
        return error.SkipZigTest;
    }

    var bound_address: std.c.sockaddr.in = undefined;
    var bound_address_len: std.c.socklen_t = @sizeOf(std.c.sockaddr.in);
    if (std.c.getsockname(fd, @ptrCast(&bound_address), &bound_address_len) != 0) {
        return error.SkipZigTest;
    }

    const port = std.mem.bigToNative(u16, bound_address.port);
    const pid = try pidForPort(std.testing.allocator, std.testing.io, port);
    try std.testing.expectEqual(@as(?i32, std.c.getpid()), pid);
}

test "kill spawned pid" {
    var child = try std.process.spawn(std.testing.io, .{
        .argv = &.{ "sleep", "30" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer child.kill(std.testing.io);

    const pid_text = try std.fmt.allocPrint(std.testing.allocator, "{d}", .{child.id.?});
    defer std.testing.allocator.free(pid_text);

    var summary = try killInputs(std.testing.allocator, std.testing.io, &.{pid_text}, .{ .force = true });
    defer summary.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), summary.errors.items.len);
    var survivors = try waitForExit(std.testing.allocator, &.{child.id.?}, 1000);
    defer survivors.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), survivors.items.len);
}

test "force-after-timeout escalates signaled pids despite unrelated input errors" {
    var child = try std.process.spawn(std.testing.io, .{
        .argv = &.{ "sh", "-c", "trap '' TERM; sleep 30" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer child.kill(std.testing.io) catch {};

    const pid_text = try std.fmt.allocPrint(std.testing.allocator, "{d}", .{child.id.?});
    defer std.testing.allocator.free(pid_text);

    var summary = try killInputs(std.testing.allocator, std.testing.io, &.{ pid_text, "definitely-not-a-running-process" }, .{
        .force_after_timeout_ms = 10,
    });
    defer summary.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), summary.errors.items.len);
    var survivors = try waitForExit(std.testing.allocator, &.{child.id.?}, 1000);
    defer survivors.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), survivors.items.len);
}
