const std = @import("std");
const cli = @import("cli.zig");
const proc = @import("process.zig");

const page_size = 10;
const choice_prefix_width = 2;

const Ansi = struct {
    const reset = "\x1b[0m";
    const bold = "\x1b[1m";
    const dim = "\x1b[2m";
    const green = "\x1b[32m";
    const cyan = "\x1b[36m";
    const magenta = "\x1b[35m";
    const hide_cursor = "\x1b[?25l";
    const show_cursor = "\x1b[?25h";
};

pub fn init(allocator: std.mem.Allocator, io: std.Io, flags: cli.Flags) !u8 {
    const stdout_file = std.Io.File.stdout();
    if (!(stdout_file.isTty(io) catch false)) {
        std.debug.print("Interactive mode requires a TTY.\n", .{});
        return 1;
    }

    var processes = try proc.listProcesses(allocator, io, false);
    defer proc.deinitProcesses(&processes, allocator);
    try proc.addPortsToProcesses(allocator, io, &processes);

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    defer stdout.flush() catch {};

    var raw = try RawMode.enable();
    defer raw.restore();

    try stdout.writeAll(Ansi.hide_cursor);
    defer stdout.writeAll(Ansi.show_cursor) catch {};

    var term: std.ArrayList(u8) = .empty;
    defer term.deinit(allocator);

    var selected: usize = 0;
    var page_start: usize = 0;
    var rendered_lines: usize = 0;
    while (true) {
        var filtered = try filterAndSortProcesses(allocator, processes.items, term.items, flags);
        defer filtered.deinit(allocator);

        if (filtered.items.len == 0) {
            selected = 0;
            page_start = 0;
        } else {
            if (selected >= filtered.items.len) {
                selected = filtered.items.len - 1;
            }

            if (selected < page_start) {
                page_start = selected;
            } else if (selected >= page_start + page_size) {
                page_start = selected + 1 - page_size;
            }

            const max_page_start = if (filtered.items.len > page_size) filtered.items.len - page_size else 0;
            if (page_start > max_page_start) {
                page_start = max_page_start;
            }
        }

        try render(stdout, allocator, filtered.items, term.items, selected, page_start, &rendered_lines, flags);
        try stdout.flush();

        var input: [8]u8 = undefined;
        const read = try std.posix.read(std.posix.STDIN_FILENO, &input);
        if (read == 0) {
            continue;
        }

        if (input[0] == 3 or input[0] == 27 and read == 1) {
            try clearRendered(stdout, rendered_lines);
            return 0;
        }

        if (input[0] == '\r' or input[0] == '\n') {
            if (filtered.items.len == 0) {
                continue;
            }

            const pid = filtered.items[selected].pid;
            try clearRendered(stdout, rendered_lines);
            try stdout.flush();
            return killSelectedProcess(allocator, io, stdout, pid);
        }

        if (read >= 3 and input[0] == 27 and input[1] == '[') {
            switch (input[2]) {
                'A' => selected = if (selected == 0) 0 else selected - 1,
                'B' => if (selected + 1 < filtered.items.len) {
                    selected += 1;
                },
                else => {},
            }
            continue;
        }

        if (input[0] == 127 or input[0] == 8) {
            if (term.items.len > 0) {
                _ = term.pop();
                selected = 0;
                page_start = 0;
            }
            continue;
        }

        if (input[0] >= 32 and input[0] != 127) {
            try term.appendSlice(allocator, input[0..read]);
            selected = 0;
            page_start = 0;
        }
    }
}

fn killSelectedProcess(allocator: std.mem.Allocator, io: std.Io, stdout: *std.Io.Writer, pid: i32) !u8 {
    var summary = try proc.attemptInteractiveKill(allocator, io, pid);
    defer summary.deinit(allocator);

    if (summary.errors.items.len == 0) {
        return 0;
    }

    try stdout.print("{s} Would you like to use the force? (y/N) ", .{summary.errors.items[0]});
    try stdout.flush();

    var answer: [1]u8 = undefined;
    const read = try std.posix.read(std.posix.STDIN_FILENO, &answer);
    try stdout.writeAll("\n");
    if (read == 1 and (answer[0] == 'y' or answer[0] == 'Y')) {
        const pid_text = try std.fmt.allocPrint(allocator, "{d}", .{pid});
        defer allocator.free(pid_text);
        var force_summary = try proc.killInputs(allocator, io, &.{pid_text}, .{ .force = true });
        defer force_summary.deinit(allocator);
        return if (force_summary.errors.items.len == 0) 0 else 1;
    }

    return 1;
}

pub fn filterAndSortProcesses(
    allocator: std.mem.Allocator,
    processes: []const proc.ProcessInfo,
    term: []const u8,
    flags: cli.Flags,
) !std.ArrayList(*const proc.ProcessInfo) {
    var filtered: std.ArrayList(*const proc.ProcessInfo) = .empty;
    errdefer filtered.deinit(allocator);

    for (processes) |*process_info| {
        if (isHelperProcess(process_info.name)) {
            continue;
        }

        if (term.len == 0 or processMatchesTerm(process_info, term, flags)) {
            try filtered.append(allocator, process_info);
        }
    }

    if (term.len == 0) {
        std.mem.sort(*const proc.ProcessInfo, filtered.items, {}, preferInteresting);
    } else {
        std.mem.sort(*const proc.ProcessInfo, filtered.items, SearchContext{ .term = term, .flags = flags }, preferSearch);
    }

    return filtered;
}

fn processMatchesTerm(process_info: *const proc.ProcessInfo, term: []const u8, flags: cli.Flags) bool {
    if (std.mem.startsWith(u8, term, ":")) {
        const port = std.fmt.parseInt(u16, term[1..], 10) catch return false;
        for (process_info.ports.items) |process_port| {
            if (process_port == port) {
                return true;
            }
        }
        return false;
    }

    if (std.fmt.parseInt(i32, term, 10) catch null) |pid| {
        if (process_info.pid == pid) {
            return true;
        }
    }

    const case_sensitive = flags.case_sensitive or (flags.smart_case and containsUppercase(term));
    return textEqual(process_info.name, term, case_sensitive) or
        textStartsWith(process_info.name, term, case_sensitive) or
        textContains(process_info.name, term, case_sensitive) or
        fuzzyMatch(process_info.name, term);
}

const SearchContext = struct {
    term: []const u8,
    flags: cli.Flags,
};

fn preferSearch(context: SearchContext, a: *const proc.ProcessInfo, b: *const proc.ProcessInfo) bool {
    const a_rank = searchRank(a, context.term, context.flags);
    const b_rank = searchRank(b, context.term, context.flags);
    if (a_rank != b_rank) {
        return a_rank < b_rank;
    }

    return std.ascii.lessThanIgnoreCase(a.name, b.name);
}

fn searchRank(process_info: *const proc.ProcessInfo, term: []const u8, flags: cli.Flags) u8 {
    if (std.mem.startsWith(u8, term, ":")) {
        return 0;
    }

    if (std.fmt.parseInt(i32, term, 10) catch null) |pid| {
        if (process_info.pid == pid) {
            return 0;
        }
    }

    const case_sensitive = flags.case_sensitive or (flags.smart_case and containsUppercase(term));
    if (textEqual(process_info.name, term, case_sensitive)) return 0;
    if (textStartsWith(process_info.name, term, case_sensitive)) return 1;
    if (textContains(process_info.name, term, case_sensitive)) return 2;
    return 3;
}

fn preferInteresting(_: void, a: *const proc.ProcessInfo, b: *const proc.ProcessInfo) bool {
    const a_deprioritized = isDeprioritizedProcess(a.name);
    const b_deprioritized = isDeprioritizedProcess(b.name);
    if (a_deprioritized != b_deprioritized) {
        return !a_deprioritized;
    }

    const a_impact = a.cpu + a.memory;
    const b_impact = b.cpu + b.memory;
    if (a_impact != b_impact) {
        return a_impact > b_impact;
    }

    return std.ascii.lessThanIgnoreCase(a.name, b.name);
}

fn render(
    stdout: *std.Io.Writer,
    allocator: std.mem.Allocator,
    processes: []const *const proc.ProcessInfo,
    term: []const u8,
    selected: usize,
    page_start: usize,
    rendered_lines: *usize,
    flags: cli.Flags,
) !void {
    try clearRendered(stdout, rendered_lines.*);

    const width = terminalWidth();
    if (term.len == 0) {
        try stdout.print("{s}?{s} {s}Running processes:{s} {s}(Use arrow keys or type to search){s}\n", .{ Ansi.green, Ansi.reset, Ansi.bold, Ansi.reset, Ansi.dim, Ansi.reset });
    } else {
        try stdout.print("{s}?{s} {s}Running processes:{s} {s}\n", .{ Ansi.green, Ansi.reset, Ansi.bold, Ansi.reset, term });
    }

    const visible_start = @min(page_start, processes.len);
    const visible_end = @min(visible_start + page_size, processes.len);
    const visible_count = visible_end - visible_start;
    for (processes[visible_start..visible_end], 0..) |process_info, index| {
        const line_width = if (width > choice_prefix_width) width - choice_prefix_width else width;
        const line = try renderProcessForDisplay(allocator, process_info, flags, line_width);
        defer allocator.free(line);

        if (visible_start + index == selected) {
            try stdout.print("{s}❯ {s}{s}\n", .{ Ansi.cyan, line, Ansi.reset });
        } else {
            try stdout.print("  {s}{s}{s}\n", .{ Ansi.dim, line, Ansi.reset });
        }
    }

    if (processes.len > page_size) {
        try stdout.print("{s}(Move up and down to reveal more choices){s}\n", .{ Ansi.dim, Ansi.reset });
        rendered_lines.* = visible_count + 2;
    } else {
        rendered_lines.* = visible_count + 1;
    }
}

fn clearRendered(stdout: *std.Io.Writer, line_count: usize) !void {
    if (line_count == 0) {
        return;
    }

    try stdout.print("\x1b[{d}A\r\x1b[J", .{line_count});
}

pub fn renderProcessForDisplay(
    allocator: std.mem.Allocator,
    process_info: *const proc.ProcessInfo,
    flags: cli.Flags,
    width: usize,
) ![]u8 {
    var ports: std.ArrayList(u8) = .empty;
    defer ports.deinit(allocator);
    const port_count = @min(process_info.ports.items.len, 4);
    for (process_info.ports.items[0..port_count]) |port| {
        const port_text = try std.fmt.allocPrint(allocator, " :{d}", .{port});
        defer allocator.free(port_text);
        try ports.appendSlice(allocator, port_text);
    }

    const memory_threshold: f64 = if (flags.verbose) 0 else 1;
    const cpu_threshold: f64 = if (flags.verbose) 0 else 3;
    const memory = if (process_info.memory > memory_threshold)
        try renderPercentage(allocator, " 🐏 ", process_info.memory)
    else
        try allocator.dupe(u8, "");
    defer allocator.free(memory);

    const cpu = if (process_info.cpu > cpu_threshold)
        try renderPercentage(allocator, "🚦 ", process_info.cpu)
    else
        try allocator.dupe(u8, "");
    defer allocator.free(cpu);

    const source_name = if (flags.verbose and process_info.cmd.len > 0) process_info.cmd else process_info.name;
    const pid_text = try std.fmt.allocPrint(allocator, "{d}", .{process_info.pid});
    defer allocator.free(pid_text);

    const port_gap = if (ports.items.len > 0 and (cpu.len > 0 or memory.len > 0)) "  " else "";
    const right_width =
        terminalDisplayWidth(ports.items) +
        terminalDisplayWidth(port_gap) +
        terminalDisplayWidth(memory) +
        terminalDisplayWidth(cpu);
    const pid_width = terminalDisplayWidth(pid_text);
    const min_column_gap: usize = if (right_width > 0) 1 else 0;
    const fixed_width = 1 + pid_width + right_width + min_column_gap;
    const name_width = if (width > fixed_width) width - fixed_width else @as(usize, 1);
    const name = try truncateMiddle(allocator, source_name, name_width);
    defer allocator.free(name);

    const name_display_width = terminalDisplayWidth(name);
    const left_width = name_display_width + 1 + pid_width;
    const spacer_len = if (right_width > 0 and width > left_width + right_width) width - left_width - right_width else 0;
    const spacer = try allocator.alloc(u8, spacer_len);
    defer allocator.free(spacer);
    @memset(spacer, ' ');

    return std.fmt.allocPrint(allocator, "{s} {s}{s}{s}{s}{s}{s}{s}{s}{s}{s}", .{
        name,
        Ansi.dim,
        pid_text,
        Ansi.reset,
        spacer,
        Ansi.magenta,
        ports.items,
        Ansi.reset,
        port_gap,
        cpu,
        memory,
    }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn renderPercentage(allocator: std.mem.Allocator, prefix: []const u8, percents: f64) ![]u8 {
    const tenths: u64 = @intFromFloat(@floor(percents * 10));
    const whole = tenths / 10;
    const fraction = tenths % 10;

    if (fraction == 0) {
        return std.fmt.allocPrint(allocator, "{s}{d}%", .{ prefix, whole });
    }

    return std.fmt.allocPrint(allocator, "{s}{d}.{d}%", .{ prefix, whole, fraction });
}

fn terminalDisplayWidth(text: []const u8) usize {
    var width: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        if (text[index] == 0x1b) {
            index += 1;
            if (index < text.len and text[index] == '[') {
                index += 1;
                while (index < text.len) : (index += 1) {
                    const byte = text[index];
                    if (byte >= '@' and byte <= '~') {
                        index += 1;
                        break;
                    }
                }
            }
            continue;
        }

        const sequence_len = std.unicode.utf8ByteSequenceLength(text[index]) catch {
            width += 1;
            index += 1;
            continue;
        };
        if (index + sequence_len > text.len) {
            width += 1;
            break;
        }

        const codepoint = std.unicode.utf8Decode(text[index..][0..sequence_len]) catch {
            width += 1;
            index += 1;
            continue;
        };
        width += codepointDisplayWidth(codepoint);
        index += sequence_len;
    }

    return width;
}

fn codepointDisplayWidth(codepoint: u21) usize {
    if (codepoint == 0 or codepoint < 32 or (codepoint >= 0x7f and codepoint < 0xa0)) {
        return 0;
    }

    if ((codepoint >= 0x1100 and codepoint <= 0x115f) or
        codepoint == 0x2329 or
        codepoint == 0x232a or
        (codepoint >= 0x2e80 and codepoint <= 0xa4cf) or
        (codepoint >= 0xac00 and codepoint <= 0xd7a3) or
        (codepoint >= 0xf900 and codepoint <= 0xfaff) or
        (codepoint >= 0xfe10 and codepoint <= 0xfe19) or
        (codepoint >= 0xfe30 and codepoint <= 0xfe6f) or
        (codepoint >= 0xff00 and codepoint <= 0xff60) or
        (codepoint >= 0xffe0 and codepoint <= 0xffe6) or
        (codepoint >= 0x1f300 and codepoint <= 0x1faff))
    {
        return 2;
    }

    return 1;
}

fn truncateMiddle(allocator: std.mem.Allocator, text: []const u8, max_len: usize) ![]u8 {
    if (text.len <= max_len) {
        return allocator.dupe(u8, text);
    }

    if (max_len <= "…".len) {
        return allocator.dupe(u8, "…");
    }

    const remaining = max_len - "…".len;
    const prefix_len = remaining / 2;
    const suffix_len = remaining - prefix_len;

    var out = try allocator.alloc(u8, prefix_len + "…".len + suffix_len);
    @memcpy(out[0..prefix_len], text[0..prefix_len]);
    @memcpy(out[prefix_len..][0.."…".len], "…");
    @memcpy(out[prefix_len + "…".len ..], text[text.len - suffix_len ..]);
    return out;
}

fn terminalWidth() usize {
    var size: std.posix.winsize = undefined;
    if (std.c.ioctl(std.posix.STDOUT_FILENO, @intCast(std.c.T.IOCGWINSZ), &size) == 0 and size.col > 0) {
        return size.col;
    }

    return 80;
}

fn isHelperProcess(name: []const u8) bool {
    return std.mem.endsWith(u8, name, "-helper") or
        std.mem.endsWith(u8, name, "Helper") or
        std.mem.endsWith(u8, name, "HelperApp");
}

fn isDeprioritizedProcess(name: []const u8) bool {
    return std.mem.eql(u8, name, "iTerm") or
        std.mem.eql(u8, name, "iTerm2") or
        std.mem.eql(u8, name, "fkill");
}

fn containsUppercase(text: []const u8) bool {
    for (text) |byte| {
        if (std.ascii.isUpper(byte)) {
            return true;
        }
    }
    return false;
}

fn textEqual(text: []const u8, needle: []const u8, case_sensitive: bool) bool {
    return if (case_sensitive) std.mem.eql(u8, text, needle) else std.ascii.eqlIgnoreCase(text, needle);
}

fn textStartsWith(text: []const u8, needle: []const u8, case_sensitive: bool) bool {
    if (needle.len > text.len) {
        return false;
    }

    return textEqual(text[0..needle.len], needle, case_sensitive);
}

fn textContains(text: []const u8, needle: []const u8, case_sensitive: bool) bool {
    if (case_sensitive) {
        return std.mem.indexOf(u8, text, needle) != null;
    }

    return std.ascii.indexOfIgnoreCase(text, needle) != null;
}

fn fuzzyMatch(text: []const u8, needle: []const u8) bool {
    if (needle.len == 0) {
        return true;
    }

    var needle_index: usize = 0;
    for (text) |byte| {
        if (std.ascii.toLower(byte) == std.ascii.toLower(needle[needle_index])) {
            needle_index += 1;
            if (needle_index == needle.len) {
                return true;
            }
        }
    }
    return false;
}

const RawMode = struct {
    original: std.posix.termios,
    active: bool = true,

    fn enable() !RawMode {
        const original = try std.posix.tcgetattr(std.posix.STDIN_FILENO);
        var raw = original;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.cc[@intFromEnum(std.c.V.MIN)] = 1;
        raw.cc[@intFromEnum(std.c.V.TIME)] = 0;
        try std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, raw);
        return .{ .original = original };
    }

    fn restore(self: *RawMode) void {
        if (!self.active) {
            return;
        }

        std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, self.original) catch {};
        self.active = false;
    }
};

test "fuzzy match uses subsequence search" {
    try std.testing.expect(fuzzyMatch("Google Chrome", "gch"));
    try std.testing.expect(!fuzzyMatch("Safari", "sx"));
}

test "filter ranks exact before contains" {
    var processes = [_]proc.ProcessInfo{
        .{ .pid = 1, .ppid = 0, .uid = 501, .cpu = 0, .memory = 0, .name = try std.testing.allocator.dupe(u8, "chrome-helper"), .cmd = try std.testing.allocator.dupe(u8, "chrome-helper") },
        .{ .pid = 2, .ppid = 0, .uid = 501, .cpu = 0, .memory = 0, .name = try std.testing.allocator.dupe(u8, "chrome"), .cmd = try std.testing.allocator.dupe(u8, "chrome") },
        .{ .pid = 3, .ppid = 0, .uid = 501, .cpu = 0, .memory = 0, .name = try std.testing.allocator.dupe(u8, "Google Chrome"), .cmd = try std.testing.allocator.dupe(u8, "Google Chrome") },
    };
    defer for (&processes) |*process_info| process_info.deinit(std.testing.allocator);

    var filtered = try filterAndSortProcesses(std.testing.allocator, &processes, "chrome", .{});
    defer filtered.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), filtered.items.len);
    try std.testing.expectEqual(@as(i32, 2), filtered.items[0].pid);
}

test "percentage rendering" {
    const text = try renderPercentage(std.testing.allocator, "🚦 ", 3.14);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualSlices(u8, "🚦 3.1%", text);
}

test "render follows selected item past first page" {
    var processes: [12]proc.ProcessInfo = undefined;
    var pointers: [12]*const proc.ProcessInfo = undefined;
    for (&processes, 0..) |*process_info, index| {
        const name = try std.fmt.allocPrint(std.testing.allocator, "App{d:0>2}", .{index});
        process_info.* = .{
            .pid = @intCast(100 + index),
            .ppid = 0,
            .uid = 501,
            .cpu = 0,
            .memory = 0,
            .name = name,
            .cmd = try std.testing.allocator.dupe(u8, name),
        };
        pointers[index] = process_info;
    }
    defer for (&processes) |*process_info| process_info.deinit(std.testing.allocator);

    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();

    var rendered_lines: usize = 0;
    try render(&writer.writer, std.testing.allocator, &pointers, "", 10, 1, &rendered_lines, .{});

    const output = writer.written();
    try std.testing.expect(std.mem.indexOf(u8, output, "App10") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "App00") == null);
}

test "badge variants use terminal column width for alignment" {
    var cpu_only = proc.ProcessInfo{
        .pid = 123,
        .ppid = 0,
        .uid = 501,
        .cpu = 4,
        .memory = 0,
        .name = try std.testing.allocator.dupe(u8, "App"),
        .cmd = try std.testing.allocator.dupe(u8, "App"),
    };
    defer cpu_only.deinit(std.testing.allocator);

    var memory_only = proc.ProcessInfo{
        .pid = 123,
        .ppid = 0,
        .uid = 501,
        .cpu = 0,
        .memory = 2,
        .name = try std.testing.allocator.dupe(u8, "App"),
        .cmd = try std.testing.allocator.dupe(u8, "App"),
    };
    defer memory_only.deinit(std.testing.allocator);

    var both = proc.ProcessInfo{
        .pid = 123,
        .ppid = 0,
        .uid = 501,
        .cpu = 4,
        .memory = 2,
        .name = try std.testing.allocator.dupe(u8, "App"),
        .cmd = try std.testing.allocator.dupe(u8, "App"),
    };
    defer both.deinit(std.testing.allocator);

    const cpu_line = try renderProcessForDisplay(std.testing.allocator, &cpu_only, .{}, 50);
    defer std.testing.allocator.free(cpu_line);
    const memory_line = try renderProcessForDisplay(std.testing.allocator, &memory_only, .{}, 50);
    defer std.testing.allocator.free(memory_line);
    const both_line = try renderProcessForDisplay(std.testing.allocator, &both, .{}, 50);
    defer std.testing.allocator.free(both_line);

    try std.testing.expectEqual(terminalDisplayWidth(cpu_line), terminalDisplayWidth(memory_line));
    try std.testing.expectEqual(terminalDisplayWidth(cpu_line), terminalDisplayWidth(both_line));
}

test "port spacing is only inserted before badges" {
    var port_only = proc.ProcessInfo{
        .pid = 123,
        .ppid = 0,
        .uid = 501,
        .cpu = 0,
        .memory = 0,
        .name = try std.testing.allocator.dupe(u8, "App"),
        .cmd = try std.testing.allocator.dupe(u8, "App"),
    };
    defer port_only.deinit(std.testing.allocator);
    try port_only.ports.append(std.testing.allocator, 5173);

    var port_with_badge = proc.ProcessInfo{
        .pid = 123,
        .ppid = 0,
        .uid = 501,
        .cpu = 4,
        .memory = 0,
        .name = try std.testing.allocator.dupe(u8, "App"),
        .cmd = try std.testing.allocator.dupe(u8, "App"),
    };
    defer port_with_badge.deinit(std.testing.allocator);
    try port_with_badge.ports.append(std.testing.allocator, 5173);

    const port_only_line = try renderProcessForDisplay(std.testing.allocator, &port_only, .{}, 50);
    defer std.testing.allocator.free(port_only_line);
    const port_with_badge_line = try renderProcessForDisplay(std.testing.allocator, &port_with_badge, .{}, 50);
    defer std.testing.allocator.free(port_with_badge_line);

    try std.testing.expect(!std.mem.endsWith(u8, port_only_line, "  "));
    try std.testing.expect(std.mem.indexOf(u8, port_with_badge_line, ":5173\x1b[0m  🚦") != null);
}

test "clear rendered moves from trailing blank line to top of previous render" {
    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();

    try clearRendered(&writer.writer, 3);
    try std.testing.expectEqualSlices(u8, "\x1b[3A\r\x1b[J", writer.written());
}
