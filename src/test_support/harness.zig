const std = @import("std");
const ShellApp = @import("../app.zig").ShellApp;
const ShellState = @import("../model/shell_state.zig").ShellState;
const config = @import("../config/config.zig");

fn tmpDirPath(allocator: std.mem.Allocator, tmp: anytype) ![]u8 {
    return try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
}

fn replaceOwnedPath(field: *[]u8, allocator: std.mem.Allocator, path: []const u8) !void {
    allocator.free(field.*);
    field.* = try allocator.dupe(u8, path);
}

test "integration: pipeline and redirection create output file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const old_cwd = try std.process.getCwdAlloc(std.testing.allocator);
    defer std.testing.allocator.free(old_cwd);
    const path = try tmpDirPath(std.testing.allocator, tmp);
    defer std.testing.allocator.free(path);
    try std.posix.chdir(path);
    defer std.posix.chdir(old_cwd) catch {};

    var app = try ShellApp.init(std.testing.allocator);
    defer app.deinit();
    app.state.interactive = false;

    _ = try app.executeText("printf 'a\\nb\\n' | grep b > out.txt\n", false);
    const output = try std.fs.cwd().readFileAlloc(std.testing.allocator, "out.txt", 1024);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("b\n", output);
}

test "integration: source mutates shell env" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const old_cwd = try std.process.getCwdAlloc(std.testing.allocator);
    defer std.testing.allocator.free(old_cwd);
    const path = try tmpDirPath(std.testing.allocator, tmp);
    defer std.testing.allocator.free(path);
    try std.posix.chdir(path);
    defer std.posix.chdir(old_cwd) catch {};

    try tmp.dir.writeFile(.{ .sub_path = "rc.sh", .data = "export NAME=zig\n" });

    var app = try ShellApp.init(std.testing.allocator);
    defer app.deinit();
    app.state.interactive = false;

    _ = try app.executeText("source rc.sh\n", false);
    try std.testing.expectEqualStrings("zig", app.state.env.get("NAME").?);
}

test "integration: parent builtin in pipeline is rejected" {
    var app = try ShellApp.init(std.testing.allocator);
    defer app.deinit();
    app.state.interactive = false;
    const exit_code = try app.executeText("cd / | cat\n", false);
    try std.testing.expectEqual(@as(u8, 1), exit_code);
}

test "integration: startup config mutates current shell state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmpDirPath(std.testing.allocator, tmp);
    defer std.testing.allocator.free(tmp_path);
    try tmp.dir.writeFile(.{ .sub_path = ".zigshrc", .data = "export RC_LOADED=1\n" });
    const rc_path = try std.fs.path.join(std.testing.allocator, &.{ tmp_path, ".zigshrc" });
    defer std.testing.allocator.free(rc_path);

    var app = try ShellApp.init(std.testing.allocator);
    defer app.deinit();
    app.state.interactive = true;
    try replaceOwnedPath(&app.state.rc_path, std.testing.allocator, rc_path);

    try app.loadStartupConfigForTest();
    try std.testing.expect(app.state.startup_loaded);
    try std.testing.expectEqualStrings("1", app.state.env.get("RC_LOADED").?);
}

test "integration: history persists across shell restarts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmpDirPath(std.testing.allocator, tmp);
    defer std.testing.allocator.free(tmp_path);
    const history_path = try std.fs.path.join(std.testing.allocator, &.{ tmp_path, ".zigsh_history" });
    defer std.testing.allocator.free(history_path);

    var state1 = try ShellState.init(std.testing.allocator, true);
    defer state1.deinit();
    try replaceOwnedPath(&state1.history_path, std.testing.allocator, history_path);
    try state1.addHistory("echo persisted");
    try config.saveHistory(&state1);

    var state2 = try ShellState.init(std.testing.allocator, true);
    defer state2.deinit();
    try replaceOwnedPath(&state2.history_path, std.testing.allocator, history_path);
    try config.loadHistory(&state2);

    try std.testing.expectEqual(@as(usize, 1), state2.history.items.len);
    try std.testing.expectEqualStrings("echo persisted", state2.history.items[0]);
}
