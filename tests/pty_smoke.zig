const std = @import("std");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len < 2) return error.InvalidArgs;

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "python3", "scripts/generate_interactive_transcript.py", args[1] },
        .cwd = ".",
        .max_output_bytes = 256 * 1024,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.fs.File.stdout().writeAll(result.stdout);
    try std.fs.File.stderr().writeAll(result.stderr);

    switch (result.term) {
        .Exited => |code| if (code != 0) return error.SmokeFailed,
        else => return error.SmokeFailed,
    }
}
