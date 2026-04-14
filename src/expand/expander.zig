const std = @import("std");
const ir = @import("../model/command_ir.zig");
const ShellState = @import("../model/shell_state.zig").ShellState;

pub fn expandWord(allocator: std.mem.Allocator, state: *const ShellState, word: ir.Word) ![]u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);

    for (word.pieces) |piece| {
        switch (piece) {
            .literal => |text| try output.appendSlice(allocator, text),
            .variable => |name| {
                if (std.mem.eql(u8, name, "?")) {
                    var buf: [16]u8 = undefined;
                    const rendered = try std.fmt.bufPrint(&buf, "{d}", .{state.last_exit_status});
                    try output.appendSlice(allocator, rendered);
                } else if (state.env.get(name)) |value| {
                    try output.appendSlice(allocator, value);
                }
            },
        }
    }

    return try output.toOwnedSlice(allocator);
}

pub fn expandWordList(allocator: std.mem.Allocator, state: *const ShellState, words: []const ir.Word) ![][]u8 {
    var result = try allocator.alloc([]u8, words.len);
    errdefer {
        for (result[0..words.len]) |item| allocator.free(item);
        allocator.free(result);
    }
    for (words, 0..) |word, i| {
        result[i] = try expandWord(allocator, state, word);
    }
    return result;
}

test "expand environment variables" {
    var state = try ShellState.init(std.testing.allocator, false);
    defer state.deinit();
    try state.setEnv("NAME", "zig");

    var pieces = [_]ir.WordPiece{
        .{ .literal = "hi " },
        .{ .variable = "NAME" },
    };
    const word = ir.Word{
        .pieces = pieces[0..],
    };
    const expanded = try expandWord(std.testing.allocator, &state, word);
    defer std.testing.allocator.free(expanded);
    try std.testing.expectEqualStrings("hi zig", expanded);
}
