const std = @import("std");
const ShellState = @import("../model/shell_state.zig").ShellState;

pub fn loadHistory(state: *ShellState) !void {
    const file = std.fs.cwd().openFile(state.history_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer file.close();

    const contents = try file.readToEndAlloc(state.allocator, 1024 * 1024);
    defer state.allocator.free(contents);
    var it = std.mem.splitScalar(u8, contents, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        try state.history.append(state.allocator, try state.allocator.dupe(u8, line));
    }
}

pub fn saveHistory(state: *ShellState) !void {
    if (!state.interactive) return;
    const file = try std.fs.cwd().createFile(state.history_path, .{ .truncate = true });
    defer file.close();
    var writer = file.deprecatedWriter();
    for (state.history.items) |line| {
        try writer.writeAll(line);
        try writer.writeByte('\n');
    }
}
