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

test "integration: type reports builtins executables and missing commands" {
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
    app.state.interactive = true;

    _ = try app.executeText("type echo /bin/sh missing_cmd > out.txt 2> err.txt\n", false);
    const out = try std.fs.cwd().readFileAlloc(std.testing.allocator, "out.txt", 4096);
    defer std.testing.allocator.free(out);
    const err = try std.fs.cwd().readFileAlloc(std.testing.allocator, "err.txt", 4096);
    defer std.testing.allocator.free(err);

    try std.testing.expect(std.mem.indexOf(u8, out, "echo is a shell builtin") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "/bin/sh") != null);
    try std.testing.expect(std.mem.indexOf(u8, err, "missing_cmd: not found") != null);
}

test "integration: stderr append redirection 2>> appends across commands" {
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

    _ = try app.executeText("/bin/sh -c 'printf first >&2' 2>> err.txt\n/bin/sh -c 'printf second >&2' 2>> err.txt\n", false);
    const err = try std.fs.cwd().readFileAlloc(std.testing.allocator, "err.txt", 4096);
    defer std.testing.allocator.free(err);
    try std.testing.expectEqualStrings("firstsecond", err);
}

test "integration: history limit affects display only" {
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
    app.state.interactive = true;
    try app.state.addHistory("echo one");
    try app.state.addHistory("echo two");
    try app.state.addHistory("echo three");

    _ = try app.executeText("history 2 > out.txt\n", false);
    const out = try std.fs.cwd().readFileAlloc(std.testing.allocator, "out.txt", 4096);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "1  echo one") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "2  echo two") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "3  echo three") != null);
}

test "integration: append history mode writes only session-created entries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmpDirPath(std.testing.allocator, tmp);
    defer std.testing.allocator.free(tmp_path);
    const history_path = try std.fs.path.join(std.testing.allocator, &.{ tmp_path, ".zigsh_history" });
    defer std.testing.allocator.free(history_path);

    var state1 = try ShellState.init(std.testing.allocator, true);
    defer state1.deinit();
    try replaceOwnedPath(&state1.history_path, std.testing.allocator, history_path);
    try state1.setEnv("HISTAPPEND", "1");
    try state1.addHistory("echo one");
    try config.saveHistory(&state1);

    var state2 = try ShellState.init(std.testing.allocator, true);
    defer state2.deinit();
    try replaceOwnedPath(&state2.history_path, std.testing.allocator, history_path);
    try state2.setEnv("HISTAPPEND", "1");
    try config.loadHistory(&state2);
    try state2.addHistory("echo two");
    try config.saveHistory(&state2);

    var state3 = try ShellState.init(std.testing.allocator, true);
    defer state3.deinit();
    try replaceOwnedPath(&state3.history_path, std.testing.allocator, history_path);
    try state3.setEnv("HISTAPPEND", "1");
    try config.loadHistory(&state3);
    try config.saveHistory(&state3);

    const contents = try std.fs.cwd().readFileAlloc(std.testing.allocator, history_path, 4096);
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings("echo one\necho two\n", contents);
}

test "integration: type works inside pipeline while parent-only builtins still reject" {
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
    app.state.interactive = true;

    _ = try app.executeText("type echo | cat > out.txt\n", false);
    const out = try std.fs.cwd().readFileAlloc(std.testing.allocator, "out.txt", 4096);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "echo is a shell builtin") != null);

    const exit_code = try app.executeText("export NAME=zig | cat\n", false);
    try std.testing.expectEqual(@as(u8, 1), exit_code);
}
