const std = @import("std");
const ir = @import("../model/command_ir.zig");
const ShellState = @import("../model/shell_state.zig").ShellState;
const JobStatus = @import("../model/shell_state.zig").JobStatus;
const ExecResult = @import("../model/result.zig").ExecResult;
const parser = @import("../parse/parser.zig");
const expander = @import("../expand/expander.zig");
const builtins = @import("builtins.zig");
const jobs = @import("jobs.zig");
const wait_status = @import("status.zig");
const signals = @import("../platform/linux/signals.zig");
const tty = @import("../platform/linux/tty.zig");

const WUNTRACED: c_int = 2;
const WCONTINUED: c_int = 8;

pub const Executor = struct {
    allocator: std.mem.Allocator,
    state: *ShellState,

    pub fn init(allocator: std.mem.Allocator, state: *ShellState) Executor {
        return .{ .allocator = allocator, .state = state };
    }

    pub fn executeText(self: *Executor, text: []const u8, record_history: bool) !ExecResult {
        var command_list = try parser.parse(self.allocator, text);
        defer command_list.deinit(self.allocator);

        if (record_history and self.state.interactive) {
            const trimmed = std.mem.trim(u8, text, " \t\r\n");
            if (trimmed.len > 0) try self.state.addHistory(trimmed);
        }

        var result = ExecResult{ .exit_code = self.state.last_exit_status };
        for (command_list.pipelines) |pipeline| {
            jobs.poll(self.state);
            result = try self.executePipeline(pipeline);
            self.state.last_exit_status = result.exit_code;
            if (result.should_exit_shell) {
                self.state.should_exit = true;
                self.state.exit_code = result.exit_code;
                break;
            }
        }
        self.state.removeCompletedJobs();
        return result;
    }

    fn executePipeline(self: *Executor, pipeline: ir.Pipeline) !ExecResult {
        var expanded = try self.expandPipeline(pipeline);
        defer expanded.deinit(self.allocator);

        if (expanded.commands.len == 1 and expanded.commands[0].argv.len == 0 and expanded.commands[0].assignments.len > 0) {
            for (expanded.commands[0].assignments) |assignment| {
                try self.state.setEnv(assignment.name, assignment.value);
            }
            return .{ .exit_code = 0 };
        }

        if (expanded.commands.len == 1 and expanded.commands[0].argv.len > 0) {
            if (builtins.lookup(expanded.commands[0].argv[0])) |builtin| {
                if (pipeline.background and builtins.isParentOnly(builtin)) {
                    try self.writeShellError("builtin cannot run in background\n");
                    return .{ .exit_code = 1 };
                }
                if (pipeline.background) {
                    try self.writeShellError("background builtins are unsupported in v1\n");
                    return .{ .exit_code = 1 };
                }
                if (builtins.isParentOnly(builtin)) {
                    return try self.runBuiltinParent(builtin, expanded.commands[0]);
                }
            }
        }

        for (expanded.commands) |command| {
            if (command.argv.len == 0) {
                try self.writeShellError("redirection-only commands are unsupported in v1\n");
                return .{ .exit_code = 1 };
            }
            if (builtins.lookup(command.argv[0])) |builtin| {
                if (builtins.isParentOnly(builtin)) {
                    try self.writeShellError("parent-mutating builtin cannot run in pipeline/background context\n");
                    return .{ .exit_code = 1 };
                }
            }
        }

        return try self.spawnPipeline(&expanded, pipeline.background);
    }

    fn expandPipeline(self: *Executor, pipeline: ir.Pipeline) !ExpandedPipeline {
        var commands = std.ArrayList(ExpandedCommand).empty;
        errdefer {
            for (commands.items) |*command| command.deinit(self.allocator);
            commands.deinit(self.allocator);
        }
        for (pipeline.commands) |command| {
            try commands.append(self.allocator, try ExpandedCommand.init(self.allocator, self.state, command));
        }
        return .{ .commands = try commands.toOwnedSlice(self.allocator), .source = pipeline.source };
    }

    fn runBuiltinParent(self: *Executor, builtin: builtins.Builtin, command: ExpandedCommand) !ExecResult {
        var restore = try RedirectRestore.apply(self.allocator, command.redirections);
        defer restore.restore();

        for (command.assignments) |assignment| {
            try self.state.setEnv(assignment.name, assignment.value);
        }

        return switch (builtin) {
            .cd => try self.builtinCd(command.argv),
            .exit => try self.builtinExit(command.argv),
            .pwd => try self.builtinPwd(command.argv, std.posix.STDOUT_FILENO),
            .@"export" => try self.builtinExport(command.argv),
            .unset => try self.builtinUnset(command.argv),
            .echo => try self.builtinEcho(command.argv, std.posix.STDOUT_FILENO),
            .jobs => try self.builtinJobs(command.argv, std.posix.STDOUT_FILENO),
            .fg => try self.builtinFg(command.argv),
            .bg => try self.builtinBg(command.argv),
            .history => try self.builtinHistory(command.argv, std.posix.STDOUT_FILENO),
            .source => try self.builtinSource(command.argv),
        };
    }

    fn spawnPipeline(self: *Executor, pipeline: *ExpandedPipeline, background: bool) !ExecResult {
        const count = pipeline.commands.len;
        var child_pids = try self.allocator.alloc(i32, count);
        defer self.allocator.free(child_pids);
        @memset(child_pids, 0);

        var previous_read: ?std.posix.fd_t = null;
        var pgid: i32 = 0;

        for (pipeline.commands, 0..) |*command, idx| {
            const is_last = idx + 1 == count;
            var pipefds: ?[2]std.posix.fd_t = null;
            if (!is_last) pipefds = try std.posix.pipe();

            const stdin_fd = previous_read orelse std.posix.STDIN_FILENO;
            const stdout_fd = if (pipefds) |fds| fds[1] else std.posix.STDOUT_FILENO;

            const pid = try self.spawnCommand(command.*, stdin_fd, stdout_fd, std.posix.STDERR_FILENO, if (pgid == 0) 0 else pgid);
            child_pids[idx] = pid;
            if (pgid == 0) pgid = pid;
            std.posix.setpgid(pid, pgid) catch {};

            if (previous_read) |fd| std.posix.close(fd);
            if (pipefds) |fds| {
                std.posix.close(fds[1]);
                previous_read = fds[0];
            } else {
                previous_read = null;
            }
        }

        if (background) {
            _ = try self.state.appendJob(pgid, pipeline.source, .running);
            var buf: [256]u8 = undefined;
            const msg = try std.fmt.bufPrint(&buf, "[{d}] {d}\n", .{ self.state.jobs.items.len, pgid });
            _ = try std.posix.write(std.posix.STDOUT_FILENO, msg);
            return .{ .exit_code = 0 };
        }

        if (self.state.interactive) tty.takeTerminal(std.posix.STDIN_FILENO, pgid);
        defer if (self.state.interactive) tty.takeTerminal(std.posix.STDIN_FILENO, self.state.shell_pgid);
        return try self.waitForegroundJob(pgid, pipeline.source);
    }

    fn waitForegroundJob(self: *Executor, pgid: i32, command_source: []const u8) !ExecResult {
        var last_exit: u8 = 0;
        while (true) {
            var raw_status: c_int = 0;
            const pid = c.waitpid(-pgid, &raw_status, WUNTRACED | WCONTINUED);
            if (pid < 0) break;
            const st: u32 = @bitCast(raw_status);
            if (wait_status.wifStopped(st)) {
                _ = try self.state.appendJob(pgid, command_source, .stopped);
                return .{ .exit_code = 128 + wait_status.wstopSig(st) };
            }
            if (wait_status.wifSignaled(st)) {
                last_exit = 128 + wait_status.wtermSig(st);
            } else if (wait_status.wifExited(st)) {
                last_exit = wait_status.wexitStatus(st);
            }
            if (!self.processGroupExists(pgid)) break;
        }
        return .{ .exit_code = last_exit };
    }

    fn processGroupExists(self: *Executor, pgid: i32) bool {
        _ = self;
        std.posix.kill(-pgid, 0) catch return false;
        return true;
    }

    fn spawnCommand(self: *Executor, command: ExpandedCommand, stdin_fd: std.posix.fd_t, stdout_fd: std.posix.fd_t, stderr_fd: std.posix.fd_t, pgid: i32) !i32 {
        if (builtins.lookup(command.argv[0])) |builtin| {
            return try self.spawnBuiltinChild(builtin, command, stdin_fd, stdout_fd, stderr_fd, pgid);
        }
        return try self.spawnExternal(command, stdin_fd, stdout_fd, stderr_fd, pgid);
    }

    fn spawnBuiltinChild(self: *Executor, builtin: builtins.Builtin, command: ExpandedCommand, stdin_fd: std.posix.fd_t, stdout_fd: std.posix.fd_t, stderr_fd: std.posix.fd_t, pgid: i32) !i32 {
        const pid = try std.posix.fork();
        if (pid == 0) {
            if (pgid == 0) {
                std.posix.setpgid(0, 0) catch {};
            } else {
                std.posix.setpgid(0, pgid) catch {};
            }
            signals.resetForChild();
            if (stdin_fd != std.posix.STDIN_FILENO) std.posix.dup2(stdin_fd, std.posix.STDIN_FILENO) catch {};
            if (stdout_fd != std.posix.STDOUT_FILENO) std.posix.dup2(stdout_fd, std.posix.STDOUT_FILENO) catch {};
            if (stderr_fd != std.posix.STDERR_FILENO) std.posix.dup2(stderr_fd, std.posix.STDERR_FILENO) catch {};
            applyChildRedirections(command.redirections) catch {
                std.posix.exit(1);
            };
            const code = self.runBuiltinChild(builtin, command) catch 1;
            std.posix.exit(code);
        }
        std.posix.setpgid(pid, if (pgid == 0) pid else pgid) catch {};
        return pid;
    }

    fn spawnExternal(self: *Executor, command: ExpandedCommand, stdin_fd: std.posix.fd_t, stdout_fd: std.posix.fd_t, stderr_fd: std.posix.fd_t, pgid: i32) !i32 {
        var env_map = std.process.EnvMap.init(self.allocator);
        defer env_map.deinit();
        var it = self.state.env.iterator();
        while (it.next()) |entry| {
            try env_map.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        for (command.assignments) |assignment| try env_map.put(assignment.name, assignment.value);

        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var argv_z = try arena.alloc(?[*:0]u8, command.argv.len + 1);
        for (command.argv, 0..) |arg, idx| argv_z[idx] = (try arena.dupeZ(u8, arg)).ptr;
        argv_z[command.argv.len] = null;
        const envp = try std.process.createNullDelimitedEnvMap(arena, &env_map);

        const pid = try std.posix.fork();
        if (pid == 0) {
            if (pgid == 0) std.posix.setpgid(0, 0) catch {} else std.posix.setpgid(0, pgid) catch {};
            signals.resetForChild();
            if (stdin_fd != std.posix.STDIN_FILENO) std.posix.dup2(stdin_fd, std.posix.STDIN_FILENO) catch {};
            if (stdout_fd != std.posix.STDOUT_FILENO) std.posix.dup2(stdout_fd, std.posix.STDOUT_FILENO) catch {};
            if (stderr_fd != std.posix.STDERR_FILENO) std.posix.dup2(stderr_fd, std.posix.STDERR_FILENO) catch {};
            applyChildRedirections(command.redirections) catch std.posix.exit(1);
            std.posix.execvpeZ(argv_z[0].?, @ptrCast(argv_z.ptr), envp.ptr) catch {
                _ = std.posix.write(std.posix.STDERR_FILENO, "exec failed\n") catch {};
                std.posix.exit(127);
            };
            unreachable;
        }
        std.posix.setpgid(pid, if (pgid == 0) pid else pgid) catch {};
        return pid;
    }

    fn builtinCd(self: *Executor, argv: [][]u8) !ExecResult {
        const target = if (argv.len >= 2) argv[1] else self.state.env.get("HOME") orelse self.state.cwd;
        std.posix.chdir(target) catch {
            try self.writeShellError("cd: failed\n");
            return .{ .exit_code = 1 };
        };
        try self.state.refreshCwd();
        return .{ .exit_code = 0 };
    }

    fn builtinExit(self: *Executor, argv: [][]u8) !ExecResult {
        const code: u8 = if (argv.len >= 2) std.fmt.parseUnsigned(u8, argv[1], 10) catch self.state.last_exit_status else self.state.last_exit_status;
        return .{ .exit_code = code, .should_exit_shell = true };
    }

    fn builtinPwd(self: *Executor, argv: [][]u8, fd: std.posix.fd_t) !ExecResult {
        _ = argv;
        _ = try std.posix.write(fd, self.state.cwd);
        _ = try std.posix.write(fd, "\n");
        return .{ .exit_code = 0 };
    }

    fn builtinExport(self: *Executor, argv: [][]u8) !ExecResult {
        if (argv.len < 2) return .{ .exit_code = 0 };
        for (argv[1..]) |item| {
            const eq = std.mem.indexOfScalar(u8, item, '=') orelse {
                try self.state.setEnv(item, "");
                continue;
            };
            try self.state.setEnv(item[0..eq], item[eq + 1 ..]);
        }
        return .{ .exit_code = 0 };
    }

    fn builtinUnset(self: *Executor, argv: [][]u8) !ExecResult {
        for (argv[1..]) |item| self.state.unsetEnv(item);
        return .{ .exit_code = 0 };
    }

    fn builtinEcho(self: *Executor, argv: [][]u8, fd: std.posix.fd_t) !ExecResult {
        _ = self;
        for (argv[1..], 0..) |item, idx| {
            if (idx != 0) _ = try std.posix.write(fd, " ");
            _ = try std.posix.write(fd, item);
        }
        _ = try std.posix.write(fd, "\n");
        return .{ .exit_code = 0 };
    }

    fn builtinJobs(self: *Executor, argv: [][]u8, fd: std.posix.fd_t) !ExecResult {
        _ = argv;
        if (!self.state.interactive) {
            try self.writeShellError("jobs: interactive mode only\n");
            return .{ .exit_code = 1 };
        }
        jobs.poll(self.state);
        try jobs.printJobs(self.state, fd);
        return .{ .exit_code = 0 };
    }

    fn builtinHistory(self: *Executor, argv: [][]u8, fd: std.posix.fd_t) !ExecResult {
        _ = argv;
        if (!self.state.interactive) {
            try self.writeShellError("history: interactive mode only\n");
            return .{ .exit_code = 1 };
        }
        for (self.state.history.items, 0..) |line, idx| {
            var buf: [2048]u8 = undefined;
            const rendered = try std.fmt.bufPrint(&buf, "{d}  {s}\n", .{ idx + 1, line });
            _ = try std.posix.write(fd, rendered);
        }
        return .{ .exit_code = 0 };
    }

    fn builtinBg(self: *Executor, argv: [][]u8) !ExecResult {
        if (!self.state.interactive) {
            try self.writeShellError("bg: interactive mode only\n");
            return .{ .exit_code = 1 };
        }
        const job_id = jobs.parseJobSpec(self.state, if (argv.len >= 2) argv[1] else null) orelse {
            try self.writeShellError("bg: no such job\n");
            return .{ .exit_code = 1 };
        };
        const job = self.state.findJobById(job_id) orelse {
            try self.writeShellError("bg: no such job\n");
            return .{ .exit_code = 1 };
        };
        try std.posix.kill(-job.pgid, std.posix.SIG.CONT);
        job.status = .running;
        return .{ .exit_code = 0 };
    }

    fn builtinFg(self: *Executor, argv: [][]u8) !ExecResult {
        if (!self.state.interactive) {
            try self.writeShellError("fg: interactive mode only\n");
            return .{ .exit_code = 1 };
        }
        const job_id = jobs.parseJobSpec(self.state, if (argv.len >= 2) argv[1] else null) orelse {
            try self.writeShellError("fg: no such job\n");
            return .{ .exit_code = 1 };
        };
        const job = self.state.findJobById(job_id) orelse {
            try self.writeShellError("fg: no such job\n");
            return .{ .exit_code = 1 };
        };
        tty.takeTerminal(std.posix.STDIN_FILENO, job.pgid);
        defer tty.takeTerminal(std.posix.STDIN_FILENO, self.state.shell_pgid);
        try std.posix.kill(-job.pgid, std.posix.SIG.CONT);
        job.status = .running;
        return try self.waitForegroundJob(job.pgid, job.command);
    }

    fn builtinSource(self: *Executor, argv: [][]u8) anyerror!ExecResult {
        if (argv.len < 2) {
            try self.writeShellError("source: missing file\n");
            return .{ .exit_code = 1 };
        }
        const contents = std.fs.cwd().readFileAlloc(self.allocator, argv[1], 1024 * 1024) catch {
            try self.writeShellError("source: failed to read file\n");
            return .{ .exit_code = 1 };
        };
        defer self.allocator.free(contents);
        return try self.executeText(contents, false);
    }

    fn runBuiltinChild(self: *Executor, builtin: builtins.Builtin, command: ExpandedCommand) !u8 {
        const result = switch (builtin) {
            .pwd => try self.builtinPwd(command.argv, std.posix.STDOUT_FILENO),
            .echo => try self.builtinEcho(command.argv, std.posix.STDOUT_FILENO),
            .history => try self.builtinHistory(command.argv, std.posix.STDOUT_FILENO),
            else => ExecResult{ .exit_code = 1 },
        };
        return result.exit_code;
    }

    fn writeShellError(self: *Executor, text: []const u8) !void {
        _ = self;
        _ = try std.posix.write(std.posix.STDERR_FILENO, text);
    }
};

const ExpandedAssignment = struct {
    name: []u8,
    value: []u8,
};

const ExpandedRedirection = struct {
    kind: ir.RedirectionKind,
    target: ?[]u8,
};

const ExpandedCommand = struct {
    argv: [][]u8,
    assignments: []ExpandedAssignment,
    redirections: []ExpandedRedirection,

    fn init(allocator: std.mem.Allocator, state: *ShellState, command: ir.SimpleCommand) !ExpandedCommand {
        var argv = std.ArrayList([]u8).empty;
        var assignments = std.ArrayList(ExpandedAssignment).empty;
        var redirections = std.ArrayList(ExpandedRedirection).empty;
        errdefer {
            for (argv.items) |item| allocator.free(item);
            argv.deinit(allocator);
            for (assignments.items) |assignment| {
                allocator.free(assignment.name);
                allocator.free(assignment.value);
            }
            assignments.deinit(allocator);
            for (redirections.items) |redir| if (redir.target) |target| allocator.free(target);
            redirections.deinit(allocator);
        }

        for (command.argv) |word| try argv.append(allocator, try expander.expandWord(allocator, state, word));
        for (command.assignments) |assignment| {
            try assignments.append(allocator, .{
                .name = try allocator.dupe(u8, assignment.name),
                .value = try expander.expandWord(allocator, state, assignment.value),
            });
        }
        for (command.redirections) |redir| {
            try redirections.append(allocator, .{
                .kind = redir.kind,
                .target = if (redir.target) |target| try expander.expandWord(allocator, state, target) else null,
            });
        }
        return .{
            .argv = try argv.toOwnedSlice(allocator),
            .assignments = try assignments.toOwnedSlice(allocator),
            .redirections = try redirections.toOwnedSlice(allocator),
        };
    }

    fn deinit(self: *ExpandedCommand, allocator: std.mem.Allocator) void {
        for (self.argv) |item| allocator.free(item);
        allocator.free(self.argv);
        for (self.assignments) |assignment| {
            allocator.free(assignment.name);
            allocator.free(assignment.value);
        }
        allocator.free(self.assignments);
        for (self.redirections) |redir| if (redir.target) |target| allocator.free(target);
        allocator.free(self.redirections);
        self.* = undefined;
    }
};

const ExpandedPipeline = struct {
    commands: []ExpandedCommand,
    source: []const u8,

    fn deinit(self: *ExpandedPipeline, allocator: std.mem.Allocator) void {
        for (self.commands) |*command| command.deinit(allocator);
        allocator.free(self.commands);
        self.* = undefined;
    }
};

const RedirectRestore = struct {
    allocator: std.mem.Allocator,
    saved: std.ArrayList(SavedFd),

    const SavedFd = struct { target_fd: std.posix.fd_t, original_fd: std.posix.fd_t };

    fn apply(allocator: std.mem.Allocator, redirections: []const ExpandedRedirection) !RedirectRestore {
        var restorer = RedirectRestore{ .allocator = allocator, .saved = .empty };
        errdefer restorer.saved.deinit(allocator);
        for (redirections) |redir| {
            switch (redir.kind) {
                .stderr_to_stdout => {
                    try restorer.pushDup(std.posix.STDERR_FILENO);
                    try std.posix.dup2(std.posix.STDOUT_FILENO, std.posix.STDERR_FILENO);
                },
                else => {
                    const fd = try openRedirection(redir);
                    defer std.posix.close(fd);
                    const target_fd: std.posix.fd_t = switch (redir.kind) {
                        .stdin_file => std.posix.STDIN_FILENO,
                        .stdout_truncate, .stdout_append => std.posix.STDOUT_FILENO,
                        .stderr_truncate => std.posix.STDERR_FILENO,
                        .stderr_to_stdout => unreachable,
                    };
                    try restorer.pushDup(target_fd);
                    try std.posix.dup2(fd, target_fd);
                },
            }
        }
        return restorer;
    }

    fn pushDup(self: *RedirectRestore, target_fd: std.posix.fd_t) !void {
        const original_fd = try std.posix.dup(target_fd);
        try self.saved.append(self.allocator, .{ .target_fd = target_fd, .original_fd = original_fd });
    }

    fn restore(self: *RedirectRestore) void {
        var idx = self.saved.items.len;
        while (idx > 0) {
            idx -= 1;
            const saved = self.saved.items[idx];
            std.posix.dup2(saved.original_fd, saved.target_fd) catch {};
            std.posix.close(saved.original_fd);
        }
        self.saved.deinit(self.allocator);
    }
};

fn applyChildRedirections(redirections: []const ExpandedRedirection) !void {
    for (redirections) |redir| {
        switch (redir.kind) {
            .stderr_to_stdout => try std.posix.dup2(std.posix.STDOUT_FILENO, std.posix.STDERR_FILENO),
            else => {
                const fd = try openRedirection(redir);
                defer std.posix.close(fd);
                const target_fd: std.posix.fd_t = switch (redir.kind) {
                    .stdin_file => std.posix.STDIN_FILENO,
                    .stdout_truncate, .stdout_append => std.posix.STDOUT_FILENO,
                    .stderr_truncate => std.posix.STDERR_FILENO,
                    .stderr_to_stdout => unreachable,
                };
                try std.posix.dup2(fd, target_fd);
            },
        }
    }
}

fn openRedirection(redir: ExpandedRedirection) !std.posix.fd_t {
    const path = redir.target orelse return error.MissingRedirectionTarget;
    return switch (redir.kind) {
        .stdin_file => std.posix.open(path, .{ .ACCMODE = .RDONLY }, 0),
        .stdout_truncate => std.posix.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644),
        .stdout_append => std.posix.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o644),
        .stderr_truncate => std.posix.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644),
        .stderr_to_stdout => unreachable,
    };
}

const c = @cImport({
    @cInclude("sys/wait.h");
});
