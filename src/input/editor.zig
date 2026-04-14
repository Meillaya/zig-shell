const std = @import("std");
const ShellState = @import("../model/shell_state.zig").ShellState;
const builtins = @import("../runtime/builtins.zig");
const tty = @import("../platform/linux/tty.zig");

pub fn readLine(allocator: std.mem.Allocator, state: *ShellState) !?[]u8 {
    var raw = try tty.RawMode.enable(std.posix.STDIN_FILENO);
    defer raw.disable(std.posix.STDIN_FILENO);

    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);

    var history_index: ?usize = null;
    var cursor: usize = 0;
    try redraw(state.prompt, buffer.items, cursor);

    while (true) {
        var byte: [1]u8 = undefined;
        const n = std.posix.read(std.posix.STDIN_FILENO, &byte) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
        if (n == 0) {
            if (buffer.items.len == 0) return null;
            break;
        }
        const ch = byte[0];
        switch (ch) {
            1 => { // Ctrl-A
                cursor = 0;
                try redraw(state.prompt, buffer.items, cursor);
            },
            5 => { // Ctrl-E
                cursor = buffer.items.len;
                try redraw(state.prompt, buffer.items, cursor);
            },
            4 => { // Ctrl-D
                if (buffer.items.len == 0) return null;
                if (cursor < buffer.items.len) {
                    _ = buffer.orderedRemove(cursor);
                    try redraw(state.prompt, buffer.items, cursor);
                }
            },
            3 => { // Ctrl-C
                buffer.clearRetainingCapacity();
                cursor = 0;
                history_index = null;
                _ = try std.posix.write(std.posix.STDOUT_FILENO, "^C\n");
                try redraw(state.prompt, buffer.items, cursor);
            },
            '\r', '\n' => {
                _ = try std.posix.write(std.posix.STDOUT_FILENO, "\n");
                break;
            },
            127, 8 => {
                if (cursor > 0) {
                    _ = buffer.orderedRemove(cursor - 1);
                    cursor -= 1;
                    try redraw(state.prompt, buffer.items, cursor);
                }
            },
            '\t' => {
                cursor = try applyCompletion(allocator, state, &buffer, cursor);
                history_index = null;
                try redraw(state.prompt, buffer.items, cursor);
            },
            27 => {
                var seq: [3]u8 = undefined;
                const read_n = std.posix.read(std.posix.STDIN_FILENO, &seq) catch 0;
                if (read_n >= 2 and seq[0] == '[') {
                    switch (seq[1]) {
                        'A' => try historyPrev(allocator, state, &buffer, &history_index, &cursor),
                        'B' => try historyNext(allocator, state, &buffer, &history_index, &cursor),
                        'C' => {
                            if (cursor < buffer.items.len) cursor += 1;
                        },
                        'D' => {
                            if (cursor > 0) cursor -= 1;
                        },
                        'H' => cursor = 0,
                        'F' => cursor = buffer.items.len,
                        else => {},
                    }
                    try redraw(state.prompt, buffer.items, cursor);
                }
            },
            else => {
                if (std.ascii.isPrint(ch)) {
                    try buffer.insert(allocator, cursor, ch);
                    cursor += 1;
                    history_index = null;
                    try redraw(state.prompt, buffer.items, cursor);
                }
            },
        }
    }

    return try buffer.toOwnedSlice(allocator);
}

fn redraw(prompt: []const u8, line: []const u8, cursor: usize) !void {
    _ = try std.posix.write(std.posix.STDOUT_FILENO, "\r\x1b[2K");
    _ = try std.posix.write(std.posix.STDOUT_FILENO, prompt);
    _ = try std.posix.write(std.posix.STDOUT_FILENO, line);
    const tail = line.len - cursor;
    if (tail > 0) {
        var buf: [32]u8 = undefined;
        const rendered = try std.fmt.bufPrint(&buf, "\x1b[{d}D", .{tail});
        _ = try std.posix.write(std.posix.STDOUT_FILENO, rendered);
    }
}

fn historyPrev(allocator: std.mem.Allocator, state: *ShellState, buffer: *std.ArrayList(u8), history_index: *?usize, cursor: *usize) !void {
    if (state.history.items.len == 0) return;
    const next_index = if (history_index.*) |idx| if (idx > 0) idx - 1 else 0 else state.history.items.len - 1;
    history_index.* = next_index;
    try setBuffer(allocator, buffer, state.history.items[next_index]);
    cursor.* = buffer.items.len;
}

fn historyNext(allocator: std.mem.Allocator, state: *ShellState, buffer: *std.ArrayList(u8), history_index: *?usize, cursor: *usize) !void {
    if (state.history.items.len == 0 or history_index.* == null) return;
    const idx = history_index.*.?;
    if (idx + 1 >= state.history.items.len) {
        history_index.* = null;
        buffer.clearRetainingCapacity();
        cursor.* = 0;
        return;
    }
    history_index.* = idx + 1;
    try setBuffer(allocator, buffer, state.history.items[idx + 1]);
    cursor.* = buffer.items.len;
}

fn setBuffer(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), value: []const u8) !void {
    buffer.clearRetainingCapacity();
    try buffer.appendSlice(allocator, value);
}

fn applyCompletion(allocator: std.mem.Allocator, state: *ShellState, buffer: *std.ArrayList(u8), cursor: usize) !usize {
    const fragment = currentFragment(buffer.items[0..cursor]);
    if (fragment.len == 0) return cursor;

    var candidates = std.ArrayList([]u8).empty;
    defer {
        for (candidates.items) |item| allocator.free(item);
        candidates.deinit(allocator);
    }

    if (std.mem.indexOfScalar(u8, fragment, '/')) |_| {
        try gatherPathCandidates(allocator, fragment, &candidates);
    } else {
        try gatherCommandCandidates(allocator, state, fragment, &candidates);
        try gatherPathCandidates(allocator, fragment, &candidates);
    }
    if (candidates.items.len == 0) return cursor;

    const replacement = if (candidates.items.len == 1) candidates.items[0] else commonPrefix(candidates.items);
    if (replacement.len > fragment.len) {
        const start = cursor - fragment.len;
        for (0..fragment.len) |_| {
            _ = buffer.orderedRemove(start);
        }
        try buffer.insertSlice(allocator, start, replacement);
        return start + replacement.len;
    } else if (candidates.items.len > 1) {
        _ = try std.posix.write(std.posix.STDOUT_FILENO, "\n");
        for (candidates.items) |candidate| {
            _ = try std.posix.write(std.posix.STDOUT_FILENO, candidate);
            _ = try std.posix.write(std.posix.STDOUT_FILENO, "\n");
        }
    }
    return cursor;
}

fn currentFragment(line: []const u8) []const u8 {
    var start = line.len;
    while (start > 0) {
        const ch = line[start - 1];
        if (ch == ' ' or ch == '\t' or ch == '|' or ch == '>' or ch == '<') break;
        start -= 1;
    }
    return line[start..];
}

fn gatherCommandCandidates(allocator: std.mem.Allocator, state: *ShellState, fragment: []const u8, out: *std.ArrayList([]u8)) !void {
    _ = state;
    for (builtins.names) |name| {
        if (std.mem.startsWith(u8, name, fragment)) try appendUnique(allocator, out, name);
    }
    const path = std.posix.getenv("PATH") orelse return;
    var path_it = std.mem.tokenizeScalar(u8, path, ':');
    while (path_it.next()) |dir_path| {
        var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch continue;
        defer dir.close();
        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .file and entry.kind != .sym_link) continue;
            if (std.mem.startsWith(u8, entry.name, fragment)) try appendUnique(allocator, out, entry.name);
        }
    }
}

fn gatherPathCandidates(allocator: std.mem.Allocator, fragment: []const u8, out: *std.ArrayList([]u8)) !void {
    const slash = std.mem.lastIndexOfScalar(u8, fragment, '/');
    const dir_name = if (slash) |idx| if (idx == 0) "/" else fragment[0..idx] else ".";
    const prefix = if (slash) |idx| fragment[idx + 1 ..] else fragment;

    var dir = if (std.mem.eql(u8, dir_name, "/"))
        try std.fs.openDirAbsolute("/", .{ .iterate = true })
    else
        std.fs.cwd().openDir(dir_name, .{ .iterate = true }) catch return;
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (std.mem.startsWith(u8, entry.name, prefix)) {
            const candidate = if (slash) |idx| try std.fmt.allocPrint(allocator, "{s}/{s}", .{ fragment[0..idx], entry.name }) else try allocator.dupe(u8, entry.name);
            errdefer allocator.free(candidate);
            for (out.items) |existing| {
                if (std.mem.eql(u8, existing, candidate)) {
                    allocator.free(candidate);
                    break;
                }
            } else {
                try out.append(allocator, candidate);
            }
        }
    }
}

fn appendUnique(allocator: std.mem.Allocator, out: *std.ArrayList([]u8), value: []const u8) !void {
    for (out.items) |existing| if (std.mem.eql(u8, existing, value)) return;
    try out.append(allocator, try allocator.dupe(u8, value));
}

fn commonPrefix(items: []const []u8) []const u8 {
    if (items.len == 0) return "";
    var end = items[0].len;
    for (items[1..]) |item| {
        end = @min(end, item.len);
        var i: usize = 0;
        while (i < end and items[0][i] == item[i]) : (i += 1) {}
        end = i;
    }
    return items[0][0..end];
}
