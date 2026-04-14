const std = @import("std");
const zig_shell = @import("zig_shell");

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa_state.deinit();
        if (leaked == .leak) @panic("memory leak detected");
    }
    const allocator = gpa_state.allocator();

    var app = try zig_shell.ShellApp.init(allocator);
    defer app.deinit();
    try app.run();
}

test "main module imports" {
    try std.testing.expect(true);
}
