const std = @import("std");

pub fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
}
