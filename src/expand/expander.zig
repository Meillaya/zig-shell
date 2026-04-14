const std = @import("std");
const ir = @import("../model/command_ir.zig");
const ShellState = @import("../model/shell_state.zig").ShellState;

pub const ExpandedWord = struct {
    text: []u8,
    glob_allowed: bool,
};

pub fn expandWord(allocator: std.mem.Allocator, state: *const ShellState, word: ir.Word) anyerror![]u8 {
    const expanded = try expandWordDetailed(allocator, state, word);
    return expanded.text;
}

pub fn expandWordDetailed(allocator: std.mem.Allocator, state: *const ShellState, word: ir.Word) anyerror!ExpandedWord {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    var glob_allowed = true;

    for (word.pieces) |piece| {
        switch (piece) {
            .literal => |data| {
                if (data.quoted) glob_allowed = false;
                try output.appendSlice(allocator, data.text);
            },
            .variable => |data| {
                if (data.quoted) glob_allowed = false;
                if (std.mem.eql(u8, data.text, "?")) {
                    var buf: [16]u8 = undefined;
                    const rendered = try std.fmt.bufPrint(&buf, "{d}", .{state.last_exit_status});
                    try output.appendSlice(allocator, rendered);
                } else if (state.env.get(data.text)) |value| {
                    try output.appendSlice(allocator, value);
                }
            },
            .command_substitution => |data| {
                if (data.quoted) glob_allowed = false;
                return error.UnsupportedFeature;
            },
        }
    }

    return .{ .text = try output.toOwnedSlice(allocator), .glob_allowed = glob_allowed };
}

pub fn expandWordForArgv(allocator: std.mem.Allocator, state: *const ShellState, word: ir.Word) anyerror![][]u8 {
    const expanded = try expandWordDetailed(allocator, state, word);
    if (expanded.glob_allowed and hasGlobMeta(expanded.text)) {
        const matches = try expandGlob(allocator, expanded.text);
        if (matches.len != 0) {
            allocator.free(expanded.text);
            return matches;
        }
        allocator.free(matches);
    }

    const single = try allocator.alloc([]u8, 1);
    single[0] = expanded.text;
    return single;
}

fn hasGlobMeta(text: []const u8) bool {
    return std.mem.indexOfAny(u8, text, "*?[") != null;
}

fn expandGlob(allocator: std.mem.Allocator, pattern: []const u8) ![][]u8 {
    const slash = std.mem.lastIndexOfScalar(u8, pattern, '/');
    const dir_name = if (slash) |idx| if (idx == 0) "/" else pattern[0..idx] else ".";
    const file_pattern = if (slash) |idx| pattern[idx + 1 ..] else pattern;

    var dir = if (std.mem.eql(u8, dir_name, "/"))
        try std.fs.openDirAbsolute("/", .{ .iterate = true })
    else
        std.fs.cwd().openDir(dir_name, .{ .iterate = true }) catch return allocator.alloc([]u8, 0);
    defer dir.close();

    var matches = std.ArrayList([]u8).empty;
    errdefer {
        for (matches.items) |item| allocator.free(item);
        matches.deinit(allocator);
    }

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (!patternMatches(file_pattern, entry.name)) continue;
        const candidate = if (slash) |idx| try std.fmt.allocPrint(allocator, "{s}/{s}", .{ pattern[0..idx], entry.name }) else try allocator.dupe(u8, entry.name);
        try matches.append(allocator, candidate);
    }

    std.mem.sort([]u8, matches.items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    return try matches.toOwnedSlice(allocator);
}

fn patternMatches(pattern: []const u8, text: []const u8) bool {
    return patternMatchesRec(pattern, text, 0, 0);
}

fn patternMatchesRec(pattern: []const u8, text: []const u8, pi: usize, ti: usize) bool {
    if (pi == pattern.len) return ti == text.len;
    if (pattern[pi] == '*') {
        var idx = ti;
        while (idx <= text.len) : (idx += 1) {
            if (patternMatchesRec(pattern, text, pi + 1, idx)) return true;
        }
        return false;
    }
    if (ti == text.len) return false;
    if (pattern[pi] == '?') return patternMatchesRec(pattern, text, pi + 1, ti + 1);
    if (pattern[pi] == '[') {
        var end = pi + 1;
        while (end < pattern.len and pattern[end] != ']') end += 1;
        if (end >= pattern.len) return false;
        const cls = pattern[pi + 1 .. end];
        if (!classMatches(cls, text[ti])) return false;
        return patternMatchesRec(pattern, text, end + 1, ti + 1);
    }
    if (pattern[pi] != text[ti]) return false;
    return patternMatchesRec(pattern, text, pi + 1, ti + 1);
}

fn classMatches(cls: []const u8, ch: u8) bool {
    var i: usize = 0;
    while (i < cls.len) : (i += 1) {
        if (i + 2 < cls.len and cls[i + 1] == '-') {
            if (cls[i] <= ch and ch <= cls[i + 2]) return true;
            i += 2;
            continue;
        }
        if (cls[i] == ch) return true;
    }
    return false;
}

test "expand environment variables" {
    var state = try ShellState.init(std.testing.allocator, false);
    defer state.deinit();
    try state.setEnv("NAME", "zig");

    var pieces = [_]ir.WordPiece{
        .{ .literal = .{ .text = "hi ", .quoted = false } },
        .{ .variable = .{ .text = "NAME", .quoted = false } },
    };
    const word = ir.Word{ .pieces = pieces[0..] };
    const expanded = try expandWord(std.testing.allocator, &state, word);
    defer std.testing.allocator.free(expanded);
    try std.testing.expectEqualStrings("hi zig", expanded);
}
