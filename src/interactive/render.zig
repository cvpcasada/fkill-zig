const std = @import("std");
const cli = @import("../cli.zig");
const proc = @import("../process.zig");
const terminal = @import("terminal.zig");

const max_page_size = 10;
const choice_prefix_width = 2;
const ellipsis = "…";

const Ansi = struct {
    const reset = "\x1b[0m";
    const bold = "\x1b[1m";
    const dim = "\x1b[2m";
    const green = "\x1b[32m";
    const cyan = "\x1b[36m";
    const magenta = "\x1b[35m";
};

pub const Layout = struct {
    page_size: usize,
    show_more_hint: bool,
};

pub fn layout(process_count: usize, terminal_height: usize) Layout {
    if (terminal_height <= 1 or process_count == 0) {
        return .{ .page_size = 0, .show_more_hint = false };
    }

    const rows_after_prompt = terminal_height - 1;
    var page_size = @min(@min(max_page_size, process_count), rows_after_prompt);
    var show_more_hint = false;

    if (process_count > page_size) {
        if (rows_after_prompt > page_size) {
            show_more_hint = true;
        } else if (page_size > 1) {
            page_size -= 1;
            show_more_hint = true;
        }
    }

    return .{ .page_size = page_size, .show_more_hint = show_more_hint };
}

pub fn render(
    stdout: *std.Io.Writer,
    allocator: std.mem.Allocator,
    processes: []const *const proc.ProcessInfo,
    term: []const u8,
    cursor: usize,
    selected: usize,
    page_start: usize,
    render_layout: Layout,
    rendered_lines: *usize,
    flags: cli.Flags,
) !void {
    try clear(stdout, rendered_lines.*);

    const width = terminal.width();
    const prompt = "? Running processes: ";
    if (term.len == 0) {
        try stdout.print("{s}?{s} {s}Running processes:{s} {s}(Use arrow keys or type to search){s}", .{ Ansi.green, Ansi.reset, Ansi.bold, Ansi.reset, Ansi.dim, Ansi.reset });
    } else {
        try stdout.print("{s}?{s} {s}Running processes:{s} {s}", .{ Ansi.green, Ansi.reset, Ansi.bold, Ansi.reset, term });
    }

    const visible_start = @min(page_start, processes.len);
    const visible_end = @min(visible_start + render_layout.page_size, processes.len);
    const visible_count = visible_end - visible_start;
    for (processes[visible_start..visible_end], 0..) |process_info, index| {
        try stdout.writeAll("\n");
        const line_width = if (width > choice_prefix_width) width - choice_prefix_width else width;
        const line = try processForDisplay(allocator, process_info, flags, line_width);
        defer allocator.free(line);

        if (visible_start + index == selected) {
            try stdout.print("{s}❯ {s}{s}", .{ Ansi.cyan, line, Ansi.reset });
        } else {
            try stdout.print("  {s}{s}{s}", .{ Ansi.dim, line, Ansi.reset });
        }
    }

    if (render_layout.show_more_hint) {
        try stdout.print("\n{s}(Move up and down to reveal more choices){s}", .{ Ansi.dim, Ansi.reset });
        rendered_lines.* = visible_count + 2;
    } else {
        rendered_lines.* = visible_count + 1;
    }

    const cursor_column = displayWidth(prompt) + displayWidth(term[0..cursor]) + 1;
    if (rendered_lines.* > 1) {
        try stdout.print("\x1b[{d}A", .{rendered_lines.* - 1});
    }
    try stdout.writeAll("\r");
    if (cursor_column > 1) {
        try stdout.print("\x1b[{d}C", .{cursor_column - 1});
    }
}

pub fn clear(stdout: *std.Io.Writer, line_count: usize) !void {
    _ = line_count;
    try stdout.writeAll("\r\x1b[J");
}

pub fn processForDisplay(
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
        try percentage(allocator, " 🐏 ", process_info.memory)
    else
        try allocator.dupe(u8, "");
    defer allocator.free(memory);

    const cpu = if (process_info.cpu > cpu_threshold)
        try percentage(allocator, "🚦 ", process_info.cpu)
    else
        try allocator.dupe(u8, "");
    defer allocator.free(cpu);

    const source_name = if (flags.verbose and process_info.cmd.len > 0) process_info.cmd else process_info.name;
    const pid_text = try std.fmt.allocPrint(allocator, "{d}", .{process_info.pid});
    defer allocator.free(pid_text);

    const port_gap = if (ports.items.len > 0 and (cpu.len > 0 or memory.len > 0)) "  " else "";
    const right_width =
        displayWidth(ports.items) +
        displayWidth(port_gap) +
        displayWidth(memory) +
        displayWidth(cpu);
    const pid_width = displayWidth(pid_text);
    const min_column_gap: usize = if (right_width > 0) 1 else 0;
    const fixed_width = 1 + pid_width + right_width + min_column_gap;
    const name_width = if (width > fixed_width) width - fixed_width else @as(usize, 1);
    const name = try truncateMiddle(allocator, source_name, name_width);
    defer allocator.free(name);

    const left_width = displayWidth(name) + 1 + pid_width;
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

fn percentage(allocator: std.mem.Allocator, prefix: []const u8, percents: f64) ![]u8 {
    const tenths: u64 = @intFromFloat(@floor(percents * 10));
    const whole = tenths / 10;
    const fraction = tenths % 10;

    if (fraction == 0) {
        return std.fmt.allocPrint(allocator, "{s}{d}%", .{ prefix, whole });
    }

    return std.fmt.allocPrint(allocator, "{s}{d}.{d}%", .{ prefix, whole, fraction });
}

pub fn displayWidth(text: []const u8) usize {
    var result: usize = 0;
    var iterator = Utf8Iterator{ .text = text };
    while (iterator.next()) |cell| {
        result += cell.width;
    }
    return result;
}

fn truncateMiddle(allocator: std.mem.Allocator, text: []const u8, max_columns: usize) ![]u8 {
    if (displayWidth(text) <= max_columns) {
        return allocator.dupe(u8, text);
    }

    const ellipsis_width = displayWidth(ellipsis);
    if (max_columns <= ellipsis_width) {
        return allocator.dupe(u8, ellipsis);
    }

    const remaining = max_columns - ellipsis_width;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try appendPrefixColumns(&out, allocator, text, remaining / 2);
    try out.appendSlice(allocator, ellipsis);
    try appendSuffixColumns(&out, allocator, text, remaining - remaining / 2);
    return out.toOwnedSlice(allocator);
}

const Utf8Cell = struct {
    bytes: []const u8,
    width: usize,
};

const Utf8Iterator = struct {
    text: []const u8,
    index: usize = 0,

    fn next(self: *Utf8Iterator) ?Utf8Cell {
        if (self.index >= self.text.len) return null;

        const start = self.index;
        const sequence_len = std.unicode.utf8ByteSequenceLength(self.text[start]) catch {
            self.index += 1;
            return .{ .bytes = self.text[start..self.index], .width = 1 };
        };
        if (start + sequence_len > self.text.len) {
            self.index = self.text.len;
            return .{ .bytes = self.text[start..], .width = 1 };
        }

        const bytes = self.text[start..][0..sequence_len];
        const codepoint = std.unicode.utf8Decode(bytes) catch {
            self.index += 1;
            return .{ .bytes = self.text[start..self.index], .width = 1 };
        };
        self.index += sequence_len;
        return .{ .bytes = bytes, .width = codepointWidth(codepoint) };
    }
};

fn appendPrefixColumns(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8, max_columns: usize) !void {
    var used: usize = 0;
    var iterator = Utf8Iterator{ .text = text };
    while (iterator.next()) |cell| {
        if (used + cell.width > max_columns) break;
        try out.appendSlice(allocator, cell.bytes);
        used += cell.width;
    }
}

fn appendSuffixColumns(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8, max_columns: usize) !void {
    var start = text.len;
    var used: usize = 0;
    var iterator = Utf8Iterator{ .text = text };
    while (iterator.next()) |cell| {
        if (used + cell.width <= max_columns) {
            used += cell.width;
        } else {
            used = suffixWidth(text[cell.bytes.ptr - text.ptr ..]);
        }
        if (used <= max_columns) {
            start = cell.bytes.ptr - text.ptr;
        }
    }
    try out.appendSlice(allocator, text[start..]);
}

fn suffixWidth(text: []const u8) usize {
    var result: usize = 0;
    var iterator = Utf8Iterator{ .text = text };
    while (iterator.next()) |cell| {
        result += cell.width;
    }
    return result;
}

fn codepointWidth(codepoint: u21) usize {
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

test "percentage rendering" {
    const text = try percentage(std.testing.allocator, "🚦 ", 3.14);
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
    try render(&writer.writer, std.testing.allocator, &pointers, "", 0, 10, 1, .{
        .page_size = 10,
        .show_more_hint = true,
    }, &rendered_lines, .{});

    const output = writer.written();
    try std.testing.expect(std.mem.indexOf(u8, output, "App10") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "App00") == null);
}

test "render layout reserves space for prompt and hint" {
    try std.testing.expectEqual(Layout{ .page_size = 0, .show_more_hint = false }, layout(12, 1));
    try std.testing.expectEqual(Layout{ .page_size = 1, .show_more_hint = false }, layout(12, 2));
    try std.testing.expectEqual(Layout{ .page_size = 1, .show_more_hint = true }, layout(12, 3));
    try std.testing.expectEqual(Layout{ .page_size = 9, .show_more_hint = true }, layout(12, 11));
    try std.testing.expectEqual(Layout{ .page_size = 10, .show_more_hint = true }, layout(12, 24));
}

test "render returns cursor to prompt after printing choices" {
    var processes: [2]proc.ProcessInfo = undefined;
    var pointers: [2]*const proc.ProcessInfo = undefined;
    for (&processes, 0..) |*process_info, index| {
        const name = try std.fmt.allocPrint(std.testing.allocator, "App{d}", .{index});
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
    try render(&writer.writer, std.testing.allocator, &pointers, "ap", 2, 0, 0, .{
        .page_size = 2,
        .show_more_hint = false,
    }, &rendered_lines, .{});

    try std.testing.expectEqual(@as(usize, 3), rendered_lines);
    try std.testing.expect(std.mem.endsWith(u8, writer.written(), "\x1b[2A\r\x1b[23C"));
    try std.testing.expect(std.mem.indexOf(u8, writer.written(), "App1\n") == null);
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

    const cpu_line = try processForDisplay(std.testing.allocator, &cpu_only, .{}, 50);
    defer std.testing.allocator.free(cpu_line);
    const memory_line = try processForDisplay(std.testing.allocator, &memory_only, .{}, 50);
    defer std.testing.allocator.free(memory_line);
    const both_line = try processForDisplay(std.testing.allocator, &both, .{}, 50);
    defer std.testing.allocator.free(both_line);

    try std.testing.expectEqual(displayWidth(cpu_line), displayWidth(memory_line));
    try std.testing.expectEqual(displayWidth(cpu_line), displayWidth(both_line));
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

    const port_only_line = try processForDisplay(std.testing.allocator, &port_only, .{}, 50);
    defer std.testing.allocator.free(port_only_line);
    const port_with_badge_line = try processForDisplay(std.testing.allocator, &port_with_badge, .{}, 50);
    defer std.testing.allocator.free(port_with_badge_line);

    try std.testing.expect(!std.mem.endsWith(u8, port_only_line, "  "));
    try std.testing.expect(std.mem.indexOf(u8, port_with_badge_line, ":5173\x1b[0m  🚦") != null);
}

test "clear rendered clears from the prompt cursor anchor" {
    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();

    try clear(&writer.writer, 0);
    try std.testing.expectEqualSlices(u8, "\r\x1b[J", writer.written());
    writer.clearRetainingCapacity();

    try clear(&writer.writer, 3);
    try std.testing.expectEqualSlices(u8, "\r\x1b[J", writer.written());
}

test "middle truncation respects UTF-8 display columns" {
    const text = try truncateMiddle(std.testing.allocator, "abcdef界ghij", 7);
    defer std.testing.allocator.free(text);

    try std.testing.expect(displayWidth(text) <= 7);
    try std.testing.expect(std.unicode.utf8ValidateSlice(text));
    try std.testing.expect(std.mem.indexOf(u8, text, ellipsis) != null);
}
