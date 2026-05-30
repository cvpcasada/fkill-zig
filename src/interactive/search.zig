const std = @import("std");
const cli = @import("../cli.zig");
const proc = @import("../process.zig");

const Match = struct {
    rank: u8,
};

const SearchContext = struct {
    term: []const u8,
    flags: cli.Flags,
};

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

        if (term.len == 0 or matchProcess(process_info, term, flags) != null) {
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

fn matchProcess(process_info: *const proc.ProcessInfo, term: []const u8, flags: cli.Flags) ?Match {
    if (std.mem.startsWith(u8, term, ":")) {
        const port = std.fmt.parseInt(u16, term[1..], 10) catch return null;
        for (process_info.ports.items) |process_port| {
            if (process_port == port) return .{ .rank = 0 };
        }
        return null;
    }

    if (std.fmt.parseInt(i32, term, 10) catch null) |pid| {
        if (process_info.pid == pid) return .{ .rank = 0 };
    }

    const case_sensitive = flags.case_sensitive or (flags.smart_case and containsUppercase(term));
    if (textEqual(process_info.name, term, case_sensitive)) return .{ .rank = 0 };
    if (textStartsWith(process_info.name, term, case_sensitive)) return .{ .rank = 1 };
    if (textContains(process_info.name, term, case_sensitive)) return .{ .rank = 2 };
    if (fuzzyMatch(process_info.name, term, case_sensitive)) return .{ .rank = 3 };
    return null;
}

fn preferSearch(context: SearchContext, a: *const proc.ProcessInfo, b: *const proc.ProcessInfo) bool {
    const a_rank = if (matchProcess(a, context.term, context.flags)) |result| result.rank else 255;
    const b_rank = if (matchProcess(b, context.term, context.flags)) |result| result.rank else 255;
    if (a_rank != b_rank) {
        return a_rank < b_rank;
    }

    return std.ascii.lessThanIgnoreCase(a.name, b.name);
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

fn fuzzyMatch(text: []const u8, needle: []const u8, case_sensitive: bool) bool {
    if (needle.len == 0) {
        return true;
    }

    var needle_index: usize = 0;
    for (text) |byte| {
        const text_byte = if (case_sensitive) byte else std.ascii.toLower(byte);
        const needle_byte = if (case_sensitive) needle[needle_index] else std.ascii.toLower(needle[needle_index]);
        if (text_byte == needle_byte) {
            needle_index += 1;
            if (needle_index == needle.len) {
                return true;
            }
        }
    }
    return false;
}

test "fuzzy match uses subsequence search" {
    try std.testing.expect(fuzzyMatch("Google Chrome", "gch", false));
    try std.testing.expect(!fuzzyMatch("Safari", "sx", false));
    try std.testing.expect(!fuzzyMatch("Google Chrome", "gch", true));
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
