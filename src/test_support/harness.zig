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

test "integration: logical operators short-circuit" {
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

    _ = try app.executeText("/bin/sh -c 'exit 0' && echo yes > and.txt\n", false);
    _ = try app.executeText("/bin/sh -c 'exit 1' || echo alt > or.txt\n", false);
    const and_out = try std.fs.cwd().readFileAlloc(std.testing.allocator, "and.txt", 1024);
    defer std.testing.allocator.free(and_out);
    const or_out = try std.fs.cwd().readFileAlloc(std.testing.allocator, "or.txt", 1024);
    defer std.testing.allocator.free(or_out);
    try std.testing.expectEqualStrings("yes\n", and_out);
    try std.testing.expectEqualStrings("alt\n", or_out);
}

test "integration: globbing expands unquoted patterns and leaves quoted literal" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const old_cwd = try std.process.getCwdAlloc(std.testing.allocator);
    defer std.testing.allocator.free(old_cwd);
    const path = try tmpDirPath(std.testing.allocator, tmp);
    defer std.testing.allocator.free(path);
    try std.posix.chdir(path);
    defer std.posix.chdir(old_cwd) catch {};
    try tmp.dir.writeFile(.{ .sub_path = "a.txt", .data = "a\n" });
    try tmp.dir.writeFile(.{ .sub_path = "b.txt", .data = "b\n" });

    var app = try ShellApp.init(std.testing.allocator);
    defer app.deinit();
    app.state.interactive = false;

    _ = try app.executeText("echo *.txt > glob.txt\n", false);
    _ = try app.executeText("echo '*.txt' > literal.txt\n", false);
    const glob = try std.fs.cwd().readFileAlloc(std.testing.allocator, "glob.txt", 1024);
    defer std.testing.allocator.free(glob);
    const literal = try std.fs.cwd().readFileAlloc(std.testing.allocator, "literal.txt", 1024);
    defer std.testing.allocator.free(literal);
    try std.testing.expect(std.mem.indexOf(u8, glob, "a.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, glob, "b.txt") != null);
    try std.testing.expectEqualStrings("*.txt\n", literal);
}

test "integration: heredoc feeds stdin" {
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

    _ = try app.executeText("cat <<EOF > heredoc.txt\nhello\nEOF\n", false);
    const out = try std.fs.cwd().readFileAlloc(std.testing.allocator, "heredoc.txt", 1024);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("hello\n", out);
}

test "integration: subshell isolates cwd and env from parent shell" {
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

    _ = try app.executeText("(cd /; export SUB=1; pwd; echo $SUB) > subshell.txt\npwd > parent.txt\n", false);
    const subshell = try std.fs.cwd().readFileAlloc(std.testing.allocator, "subshell.txt", 4096);
    defer std.testing.allocator.free(subshell);
    const parent = try std.fs.cwd().readFileAlloc(std.testing.allocator, "parent.txt", 4096);
    defer std.testing.allocator.free(parent);
    const actual_cwd = try std.process.getCwdAlloc(std.testing.allocator);
    defer std.testing.allocator.free(actual_cwd);
    const expected_parent = try std.fmt.allocPrint(std.testing.allocator, "{s}\n", .{actual_cwd});
    defer std.testing.allocator.free(expected_parent);
    try std.testing.expect(std.mem.indexOf(u8, subshell, "/\n1\n") != null);
    try std.testing.expectEqualStrings(expected_parent, parent);
    try std.testing.expect(app.state.env.get("SUB") == null);
}

test "integration: subshell participates in pipeline and redirection" {
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

    _ = try app.executeText("(printf hi) | cat > pipe.txt\n(printf bye) > redir.txt\n", false);
    const pipe_out = try std.fs.cwd().readFileAlloc(std.testing.allocator, "pipe.txt", 1024);
    defer std.testing.allocator.free(pipe_out);
    const redir_out = try std.fs.cwd().readFileAlloc(std.testing.allocator, "redir.txt", 1024);
    defer std.testing.allocator.free(redir_out);
    try std.testing.expectEqualStrings("hi", pipe_out);
    try std.testing.expectEqualStrings("bye", redir_out);
}

test "integration: command substitution uses shell semantics for builtins" {
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

    _ = try app.executeText("echo $(type echo) > subst-type.txt\n", false);
    const out = try std.fs.cwd().readFileAlloc(std.testing.allocator, "subst-type.txt", 4096);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "echo is a shell builtin") != null);
}

test "integration: bounded function definition and invocation works" {
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

    _ = try app.executeText("greet() { echo hello; }\ngreet > out.txt\n", false);
    const out = try std.fs.cwd().readFileAlloc(std.testing.allocator, "out.txt", 1024);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("hello\n", out);
}

test "integration: function positional args and precedence work" {
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

    _ = try app.executeText("echo() { printf '%s %s' $1 $2; }\necho one two > out.txt\ntype echo > type.txt\n", false);
    const out = try std.fs.cwd().readFileAlloc(std.testing.allocator, "out.txt", 1024);
    defer std.testing.allocator.free(out);
    const type_out = try std.fs.cwd().readFileAlloc(std.testing.allocator, "type.txt", 1024);
    defer std.testing.allocator.free(type_out);
    try std.testing.expectEqualStrings("one two", out);
    try std.testing.expect(std.mem.indexOf(u8, type_out, "echo is a shell function") != null);
}

test "integration: special builtin precedence beats function name collision" {
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

    _ = try app.executeText("cd() { echo nope; }\ntype cd > type.txt\n", false);
    const type_out = try std.fs.cwd().readFileAlloc(std.testing.allocator, "type.txt", 1024);
    defer std.testing.allocator.free(type_out);
    try std.testing.expect(std.mem.indexOf(u8, type_out, "cd is a shell builtin") != null);
}

test "integration: functions isolate across subshell and command substitution contexts" {
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

    _ = try app.executeText("outer() { echo outer; }\necho $(outer) > subst.txt\n(foo() { echo sub; })\ntype foo > type.txt 2> err.txt\n", false);
    const subst = try std.fs.cwd().readFileAlloc(std.testing.allocator, "subst.txt", 1024);
    defer std.testing.allocator.free(subst);
    const err = try std.fs.cwd().readFileAlloc(std.testing.allocator, "err.txt", 1024);
    defer std.testing.allocator.free(err);
    try std.testing.expectEqualStrings("outer\n", subst);
    try std.testing.expect(std.mem.indexOf(u8, err, "foo: not found") != null);
}

test "integration: command substitution works in basic argument position" {
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

    _ = try app.executeText("echo $(printf hi) > subst.txt\n", false);
    const out = try std.fs.cwd().readFileAlloc(std.testing.allocator, "subst.txt", 1024);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("hi\n", out);
}
