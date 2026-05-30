const std = @import("std");
const cli = @import("cli.zig");
const input = @import("interactive/input.zig");
const proc = @import("process.zig");
const render = @import("interactive/render.zig");
const search = @import("interactive/search.zig");
const terminal = @import("interactive/terminal.zig");

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

    var raw = try terminal.RawMode.enable();
    defer raw.restore();

    var rendered_lines: usize = 0;
    var term: input.SearchInput = .{};
    defer term.deinit(allocator);

    var reader = input.Reader{ .fd = std.posix.STDIN_FILENO };
    var selected: usize = 0;
    var page_start: usize = 0;
    while (true) {
        term.resetCursor();
        var filtered = try search.filterAndSortProcesses(allocator, processes.items, term.text.items, flags);
        defer filtered.deinit(allocator);

        const current_layout = render.layout(filtered.items.len, terminal.height());
        clampSelection(filtered.items.len, current_layout.page_size, &selected, &page_start);

        try render.render(stdout, allocator, filtered.items, term.text.items, term.cursor, selected, page_start, current_layout, &rendered_lines, flags);
        try stdout.flush();

        const action = try reader.readAction();
        switch (action) {
            .cancel => {
                try render.clear(stdout, rendered_lines);
                return 0;
            },
            .submit => {
                if (filtered.items.len == 0) continue;

                const pid = filtered.items[selected].pid;
                try render.clear(stdout, rendered_lines);
                raw.restore();
                try stdout.flush();
                return killSelectedProcess(allocator, io, stdout, pid);
            },
            .move_up => selected = if (selected == 0) 0 else selected - 1,
            .move_down => if (selected + 1 < filtered.items.len) {
                selected += 1;
            },
            .none => {},
            else => if (try term.apply(allocator, action)) {
                selected = 0;
                page_start = 0;
            },
        }
    }
}

fn clampSelection(process_count: usize, page_size: usize, selected: *usize, page_start: *usize) void {
    if (process_count == 0) {
        selected.* = 0;
        page_start.* = 0;
        return;
    }

    if (selected.* >= process_count) {
        selected.* = process_count - 1;
    }

    if (selected.* < page_start.*) {
        page_start.* = selected.*;
    } else if (page_size > 0 and selected.* >= page_start.* + page_size) {
        page_start.* = selected.* + 1 - page_size;
    }

    if (page_size == 0) {
        page_start.* = selected.*;
    } else {
        const max_page_start = if (process_count > page_size) process_count - page_size else 0;
        if (page_start.* > max_page_start) {
            page_start.* = max_page_start;
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

test {
    _ = input;
    _ = render;
    _ = search;
    _ = terminal;
}
