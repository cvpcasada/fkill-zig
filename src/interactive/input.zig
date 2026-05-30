const std = @import("std");

const escape_sequence_wait_ms = 25;

pub const SearchInput = struct {
    text: std.ArrayList(u8) = .empty,
    cursor: usize = 0,

    pub fn deinit(self: *SearchInput, allocator: std.mem.Allocator) void {
        self.text.deinit(allocator);
    }

    pub fn resetCursor(self: *SearchInput) void {
        if (self.cursor > self.text.items.len) {
            self.cursor = self.text.items.len;
        }
    }

    pub fn apply(self: *SearchInput, allocator: std.mem.Allocator, action: Action) !bool {
        switch (action) {
            .cursor_start => self.cursor = 0,
            .cursor_end => self.cursor = self.text.items.len,
            .cursor_left => self.moveLeft(),
            .cursor_right => self.moveRight(),
            .word_left => self.moveWordLeft(),
            .word_right => self.moveWordRight(),
            .backspace => {
                if (self.cursor == 0) return false;
                self.backspace();
                return true;
            },
            .delete_forward => {
                if (self.cursor >= self.text.items.len) return false;
                self.deleteForward();
                return true;
            },
            .delete_word_before => {
                if (self.cursor == 0) return false;
                self.deleteWordBeforeCursor();
                return true;
            },
            .delete_word_after => {
                if (self.cursor >= self.text.items.len) return false;
                self.deleteWordAfterCursor();
                return true;
            },
            .delete_before => {
                if (self.cursor == 0) return false;
                self.deleteBeforeCursor();
                return true;
            },
            .delete_after => {
                if (self.cursor >= self.text.items.len) return false;
                self.deleteAfterCursor();
                return true;
            },
            .insert_text => |bytes| {
                try self.text.insertSlice(allocator, self.cursor, bytes);
                self.cursor += bytes.len;
                return true;
            },
            .cancel, .submit, .move_up, .move_down, .none => {},
        }

        return false;
    }

    fn moveLeft(self: *SearchInput) void {
        if (self.cursor == 0) return;

        self.cursor -= 1;
        while (self.cursor > 0 and (self.text.items[self.cursor] & 0xc0) == 0x80) {
            self.cursor -= 1;
        }
    }

    fn moveRight(self: *SearchInput) void {
        if (self.cursor >= self.text.items.len) return;

        self.cursor += 1;
        while (self.cursor < self.text.items.len and (self.text.items[self.cursor] & 0xc0) == 0x80) {
            self.cursor += 1;
        }
    }

    fn moveWordLeft(self: *SearchInput) void {
        while (self.cursor > 0 and std.ascii.isWhitespace(self.text.items[self.cursor - 1])) {
            self.moveLeft();
        }
        while (self.cursor > 0 and !std.ascii.isWhitespace(self.text.items[self.cursor - 1])) {
            self.moveLeft();
        }
    }

    fn moveWordRight(self: *SearchInput) void {
        while (self.cursor < self.text.items.len and std.ascii.isWhitespace(self.text.items[self.cursor])) {
            self.moveRight();
        }
        while (self.cursor < self.text.items.len and !std.ascii.isWhitespace(self.text.items[self.cursor])) {
            self.moveRight();
        }
    }

    fn backspace(self: *SearchInput) void {
        const end = self.cursor;
        self.moveLeft();
        self.text.replaceRangeAssumeCapacity(self.cursor, end - self.cursor, "");
    }

    fn deleteForward(self: *SearchInput) void {
        const start = self.cursor;
        self.moveRight();
        self.text.replaceRangeAssumeCapacity(start, self.cursor - start, "");
        self.cursor = start;
    }

    fn deleteWordBeforeCursor(self: *SearchInput) void {
        const end = self.cursor;
        self.moveWordLeft();
        const start = self.cursor;
        self.cursor = end;
        self.text.replaceRangeAssumeCapacity(start, self.cursor - start, "");
        self.cursor = start;
    }

    fn deleteWordAfterCursor(self: *SearchInput) void {
        const start = self.cursor;
        self.moveWordRight();
        self.text.replaceRangeAssumeCapacity(start, self.cursor - start, "");
        self.cursor = start;
    }

    fn deleteBeforeCursor(self: *SearchInput) void {
        self.text.replaceRangeAssumeCapacity(0, self.cursor, "");
        self.cursor = 0;
    }

    fn deleteAfterCursor(self: *SearchInput) void {
        self.text.shrinkRetainingCapacity(self.cursor);
    }
};

pub const Reader = struct {
    fd: std.posix.fd_t,
    buffer: [8]u8 = undefined,

    pub fn readAction(self: *Reader) !Action {
        var len = try std.posix.read(self.fd, &self.buffer);
        if (len == 0) {
            return .none;
        }

        if (self.buffer[0] == 27) {
            while (len < self.buffer.len and !escapeSequenceComplete(self.buffer[0..len])) {
                if (!try inputAvailable(self.fd)) {
                    break;
                }

                const read = try std.posix.read(self.fd, self.buffer[len..]);
                if (read == 0) {
                    break;
                }
                len += read;
            }
        }

        return decode(self.buffer[0..len]);
    }
};

pub const Action = union(enum) {
    cancel,
    submit,
    move_up,
    move_down,
    cursor_start,
    cursor_end,
    cursor_left,
    cursor_right,
    word_left,
    word_right,
    backspace,
    delete_forward,
    delete_word_before,
    delete_word_after,
    delete_before,
    delete_after,
    insert_text: []const u8,
    none,
};

fn inputAvailable(fd: std.posix.fd_t) !bool {
    var fds = [_]std.posix.pollfd{.{
        .fd = fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ready = try std.posix.poll(&fds, escape_sequence_wait_ms);
    return ready > 0 and (fds[0].revents & std.posix.POLL.IN) == std.posix.POLL.IN;
}

fn escapeSequenceComplete(bytes: []const u8) bool {
    if (bytes.len == 0 or bytes[0] != 27) {
        return true;
    }
    if (bytes.len == 1) {
        return false;
    }
    if (bytes[1] != '[') {
        return true;
    }
    if (bytes.len < 3) {
        return false;
    }

    return switch (bytes[2]) {
        'A', 'B', 'C', 'D', 'F', 'H' => true,
        '1' => bytes.len >= 6,
        '3' => bytes.len >= 4,
        else => true,
    };
}

pub fn decode(bytes: []const u8) Action {
    if (bytes.len == 0) return .none;

    switch (bytes[0]) {
        3 => return .cancel,
        27 => {
            if (bytes.len == 1) return .cancel;
            return decodeEscape(bytes);
        },
        '\r', '\n' => return .submit,
        1 => return .cursor_start,
        2 => return .cursor_left,
        5 => return .cursor_end,
        6 => return .cursor_right,
        11 => return .delete_after,
        21 => return .delete_before,
        23 => return .delete_word_before,
        127, 8 => return .backspace,
        else => if (bytes[0] >= 32 and bytes[0] != 127) return .{ .insert_text = bytes },
    }

    return .none;
}

fn decodeEscape(bytes: []const u8) Action {
    if (bytes.len >= 2 and bytes[1] != '[') {
        return switch (bytes[1]) {
            127 => .delete_word_before,
            'b' => .word_left,
            'd' => .delete_word_after,
            'f' => .word_right,
            else => .none,
        };
    }

    if (bytes.len < 3 or bytes[1] != '[') return .none;
    return switch (bytes[2]) {
        'A' => .move_up,
        'B' => .move_down,
        'C' => .cursor_right,
        'D' => .cursor_left,
        'F' => .cursor_end,
        'H' => .cursor_start,
        '1' => if (bytes.len >= 6 and bytes[3] == ';' and bytes[4] == '5')
            switch (bytes[5]) {
                'C' => .word_right,
                'D' => .word_left,
                else => .none,
            }
        else
            .none,
        '3' => if (bytes.len >= 4 and bytes[3] == '~') .delete_forward else .none,
        else => .none,
    };
}

test "search input edits around the cursor" {
    var term: SearchInput = .{};
    defer term.deinit(std.testing.allocator);

    try std.testing.expect(try term.apply(std.testing.allocator, .{ .insert_text = "chrome" }));
    _ = try term.apply(std.testing.allocator, .cursor_left);
    _ = try term.apply(std.testing.allocator, .cursor_left);
    try std.testing.expect(try term.apply(std.testing.allocator, .{ .insert_text = "mi" }));
    try std.testing.expectEqualSlices(u8, "chromie", term.text.items);

    try std.testing.expect(try term.apply(std.testing.allocator, .backspace));
    try std.testing.expectEqualSlices(u8, "chrome", term.text.items);

    try std.testing.expect(try term.apply(std.testing.allocator, .delete_forward));
    try std.testing.expectEqualSlices(u8, "chrom", term.text.items);
}

test "search input supports line and word deletion" {
    var term: SearchInput = .{};
    defer term.deinit(std.testing.allocator);

    _ = try term.apply(std.testing.allocator, .{ .insert_text = "Google Chrome Helper" });
    _ = try term.apply(std.testing.allocator, .word_left);
    try std.testing.expectEqual(@as(usize, "Google Chrome ".len), term.cursor);
    _ = try term.apply(std.testing.allocator, .word_right);
    try std.testing.expectEqual(@as(usize, "Google Chrome Helper".len), term.cursor);

    try std.testing.expect(try term.apply(std.testing.allocator, .delete_word_before));
    try std.testing.expectEqualSlices(u8, "Google Chrome ", term.text.items);

    term.cursor = "Google ".len;
    try std.testing.expect(try term.apply(std.testing.allocator, .delete_word_after));
    try std.testing.expectEqualSlices(u8, "Google ", term.text.items);

    _ = try term.apply(std.testing.allocator, .{ .insert_text = "Chrome Helper" });
    term.cursor = "Google ".len;
    try std.testing.expect(try term.apply(std.testing.allocator, .delete_after));
    try std.testing.expectEqualSlices(u8, "Google ", term.text.items);

    try std.testing.expect(try term.apply(std.testing.allocator, .delete_before));
    try std.testing.expectEqualSlices(u8, "", term.text.items);
    try std.testing.expectEqual(@as(usize, 0), term.cursor);
}

test "decoder emits typed actions" {
    try std.testing.expectEqual(Action.cancel, decode(&.{3}));
    try std.testing.expectEqual(Action.submit, decode("\n"));
    try std.testing.expectEqual(Action.move_up, decode("\x1b[A"));
    try std.testing.expectEqual(Action.word_right, decode("\x1b[1;5C"));
    try std.testing.expectEqual(Action.delete_word_before, decode("\x1b\x7f"));

    const action = decode("x");
    try std.testing.expectEqualSlices(u8, "x", action.insert_text);
}

test "escape sequence completion distinguishes standalone escape from partial keys" {
    try std.testing.expect(!escapeSequenceComplete("\x1b"));
    try std.testing.expect(!escapeSequenceComplete("\x1b["));
    try std.testing.expect(escapeSequenceComplete("\x1b[A"));
    try std.testing.expect(!escapeSequenceComplete("\x1b[1;5"));
    try std.testing.expect(escapeSequenceComplete("\x1b[1;5C"));
}
