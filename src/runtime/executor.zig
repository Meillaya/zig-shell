const std = @import("std");
const ir = @import("../model/command_ir.zig");
const ShellState = @import("../model/shell_state.zig").ShellState;
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
const CommandNotFoundError = error{CommandNotFound};
const SupportedFeatureError = error{UnsupportedFeature};

pub const Executor = struct {
    allocator: std.mem.Allocator,
    state: *ShellState,

    pub fn init(allocator: std.mem.Allocator, state: *ShellState) Executor {
        return .{ .allocator = allocator, .state = state };
    }

    pub fn executeText(self: *Executor, text: []const u8, record_history: bool) anyerror!ExecResult {
        var preprocessed = try preprocessHeredocs(self.allocator, text);
        defer preprocessed.deinit(self.allocator);

        if (record_history and self.state.interactive) {
            const trimmed = std.mem.trim(u8, text, " \t\r\n");
            if (trimmed.len > 0) try self.state.addHistory(trimmed);
        }

        return try self.executeLogicalChain(preprocessed.text);
    }

    fn executeLogicalChain(self: *Executor, text: []const u8) anyerror!ExecResult {
        var chain = try splitLogicalChain(self.allocator, text);
        defer chain.deinit(self.allocator);

        var result = ExecResult{ .exit_code = self.state.last_exit_status };
        for (chain.segments, 0..) |segment, idx| {
            if (idx > 0) {
                switch (chain.ops[idx - 1]) {
                    .and_and => if (result.exit_code != 0) continue,
                    .or_or => if (result.exit_code == 0) continue,
                }
            }

            var command_list = try parser.parse(self.allocator, segment);
            defer command_list.deinit(self.allocator);
            jobs.poll(self.state);
            for (command_list.pipelines) |pipeline| {
                result = try self.executePipeline(pipeline);
                self.state.last_exit_status = result.exit_code;
                if (result.should_exit_shell) {
                    self.state.should_exit = true;
                    self.state.exit_code = result.exit_code;
                    break;
                }
            }
            if (result.should_exit_shell) break;
        }
        self.state.removeCompletedJobs();
        return result;
    }

    fn executePipeline(self: *Executor, pipeline: ir.Pipeline) anyerror!ExecResult {
        var expanded = try self.expandPipeline(pipeline);
        defer expanded.deinit(self.allocator);

        if (expanded.commands.len == 1) {
            switch (expanded.commands[0]) {
                .simple => |command| {
                    if (command.argv.len == 0 and command.assignments.len > 0) {
                        for (command.assignments) |assignment| {
                            try self.state.setEnv(assignment.name, assignment.value);
                        }
                        return .{ .exit_code = 0 };
                    }
                },
                .subshell => {},
            }
        }

        if (expanded.commands.len == 1) {
            switch (expanded.commands[0]) {
                .simple => |command| {
                    if (command.argv.len > 0) {
                        if (builtins.lookup(command.argv[0])) |builtin| {
                            if (pipeline.background and builtins.isParentOnly(builtin)) {
                                try self.writeShellError("builtin cannot run in background\n");
                                return .{ .exit_code = 1 };
                            }
                            if (pipeline.background) {
                                try self.writeShellError("background builtins are unsupported in v1\n");
                                return .{ .exit_code = 1 };
                            }
                            if (builtins.isParentOnly(builtin)) {
                                return try self.runBuiltinParent(builtin, command);
                            }
                        }
                    }
                },
                .subshell => {},
            }
        }

        for (expanded.commands) |command| {
            switch (command) {
                .simple => |simple| {
                    if (simple.argv.len == 0) {
                        try self.writeShellError("redirection-only commands are unsupported in v1\n");
                        return .{ .exit_code = 1 };
                    }
                    if (builtins.lookup(simple.argv[0])) |builtin| {
                        if (builtins.isParentOnly(builtin)) {
                            try self.writeShellError("parent-mutating builtin cannot run in pipeline/background context\n");
                            return .{ .exit_code = 1 };
                        }
                    }
                },
                .subshell => {},
            }
        }

        return try self.spawnPipeline(&expanded, pipeline.background);
    }

    fn expandPipeline(self: *Executor, pipeline: ir.Pipeline) !ExpandedPipeline {
        var commands = std.ArrayList(ExpandedCommandNode).empty;
        errdefer {
            for (commands.items) |*command| command.deinit(self.allocator);
            commands.deinit(self.allocator);
        }
        for (pipeline.commands) |command| {
            switch (command) {
                .simple => |simple| try commands.append(self.allocator, .{ .simple = try ExpandedCommand.init(self.allocator, self.state, simple) }),
                .subshell => |subshell| try commands.append(self.allocator, .{ .subshell = try ExpandedSubshell.init(self.allocator, self.state, subshell) }),
            }
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
            .type => try self.builtinType(command.argv, std.posix.STDOUT_FILENO),
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

            const pid = self.spawnCommand(command.*, stdin_fd, stdout_fd, std.posix.STDERR_FILENO, if (pgid == 0) 0 else pgid) catch |err| switch (err) {
                error.CommandNotFound => return .{ .exit_code = 127 },
                else => return err,
            };
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
            _ = try self.state.appendJob(pgid, pipeline.source, .running, count);
            var buf: [256]u8 = undefined;
            const msg = try std.fmt.bufPrint(&buf, "[{d}] {d}\n", .{ self.state.findLatestJob().?.id, pgid });
            _ = try std.posix.write(std.posix.STDOUT_FILENO, msg);
            return .{ .exit_code = 0 };
        }

        if (self.state.interactive) tty.takeTerminal(std.posix.STDIN_FILENO, pgid);
        defer if (self.state.interactive) tty.takeTerminal(std.posix.STDIN_FILENO, self.state.shell_pgid);
        return try self.waitForegroundJob(pgid, pipeline.source, count);
    }

    fn waitForegroundJob(self: *Executor, pgid: i32, command_source: []const u8, process_count: usize) !ExecResult {
        var last_exit: u8 = 0;
        var remaining = process_count;
        while (true) {
            var raw_status: c_int = 0;
            const pid = c.waitpid(-pgid, &raw_status, WUNTRACED | WCONTINUED);
            if (pid < 0) break;
            const st: u32 = @bitCast(raw_status);
            if (wait_status.wifStopped(st)) {
                _ = try self.state.appendJob(pgid, command_source, .stopped, remaining);
                return .{ .exit_code = 128 + wait_status.wstopSig(st) };
            }
            if (wait_status.wifSignaled(st)) {
                last_exit = 128 + wait_status.wtermSig(st);
                if (remaining > 0) remaining -= 1;
            } else if (wait_status.wifExited(st)) {
                last_exit = wait_status.wexitStatus(st);
                if (remaining > 0) remaining -= 1;
            }
            if (remaining == 0) break;
        }
        return .{ .exit_code = last_exit };
    }

    fn spawnCommand(self: *Executor, command: ExpandedCommandNode, stdin_fd: std.posix.fd_t, stdout_fd: std.posix.fd_t, stderr_fd: std.posix.fd_t, pgid: i32) (CommandNotFoundError || SupportedFeatureError || anyerror)!i32 {
        return switch (command) {
            .simple => |simple| blk: {
                if (builtins.lookup(simple.argv[0])) |builtin| {
                    break :blk try self.spawnBuiltinChild(builtin, simple, stdin_fd, stdout_fd, stderr_fd, pgid);
                }
                break :blk try self.spawnExternal(simple, stdin_fd, stdout_fd, stderr_fd, pgid);
            },
            .subshell => |subshell| try self.spawnSubshell(subshell, stdin_fd, stdout_fd, stderr_fd, pgid),
        };
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

    fn spawnExternal(self: *Executor, command: ExpandedCommand, stdin_fd: std.posix.fd_t, stdout_fd: std.posix.fd_t, stderr_fd: std.posix.fd_t, pgid: i32) (CommandNotFoundError || anyerror)!i32 {
        var env_map = try command.makeEnvMap(self.allocator, self.state);
        defer env_map.deinit();
        const resolved = try self.resolveExecutablePath(&env_map, command.argv[0]) orelse {
            try self.writeShellErrorFmt("{s}: not found\n", .{command.argv[0]});
            return error.CommandNotFound;
        };
        defer self.allocator.free(resolved);

        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var argv_z = try arena.alloc(?[*:0]u8, command.argv.len + 1);
        for (command.argv, 0..) |arg, idx| argv_z[idx] = (try arena.dupeZ(u8, arg)).ptr;
        argv_z[command.argv.len] = null;
        const resolved_z = try arena.dupeZ(u8, resolved);
        const envp = try std.process.createNullDelimitedEnvMap(arena, &env_map);

        const pid = try std.posix.fork();
        if (pid == 0) {
            if (pgid == 0) std.posix.setpgid(0, 0) catch {} else std.posix.setpgid(0, pgid) catch {};
            signals.resetForChild();
            if (stdin_fd != std.posix.STDIN_FILENO) std.posix.dup2(stdin_fd, std.posix.STDIN_FILENO) catch {};
            if (stdout_fd != std.posix.STDOUT_FILENO) std.posix.dup2(stdout_fd, std.posix.STDOUT_FILENO) catch {};
            if (stderr_fd != std.posix.STDERR_FILENO) std.posix.dup2(stderr_fd, std.posix.STDERR_FILENO) catch {};
            applyChildRedirections(command.redirections) catch std.posix.exit(1);
            std.posix.execveZ(resolved_z.ptr, @ptrCast(argv_z.ptr), envp.ptr) catch {
                _ = std.posix.write(std.posix.STDERR_FILENO, "exec failed\n") catch {};
                std.posix.exit(127);
            };
            unreachable;
        }
        std.posix.setpgid(pid, if (pgid == 0) pid else pgid) catch {};
        return pid;
    }

    fn spawnSubshell(self: *Executor, subshell: ExpandedSubshell, stdin_fd: std.posix.fd_t, stdout_fd: std.posix.fd_t, stderr_fd: std.posix.fd_t, pgid: i32) !i32 {
        const pid = try std.posix.fork();
        if (pid == 0) {
            if (pgid == 0) std.posix.setpgid(0, 0) catch {} else std.posix.setpgid(0, pgid) catch {};
            signals.resetForChild();
            if (stdin_fd != std.posix.STDIN_FILENO) std.posix.dup2(stdin_fd, std.posix.STDIN_FILENO) catch {};
            if (stdout_fd != std.posix.STDOUT_FILENO) std.posix.dup2(stdout_fd, std.posix.STDOUT_FILENO) catch {};
            if (stderr_fd != std.posix.STDERR_FILENO) std.posix.dup2(stderr_fd, std.posix.STDERR_FILENO) catch {};
            applyChildRedirections(subshell.redirections) catch std.posix.exit(1);

            var child_state = self.state.*;
            child_state.interactive = false;
            child_state.should_exit = false;
            child_state.exit_code = 0;
            child_state.jobs = .empty;
            child_state.free_job_ids = .empty;
            defer child_state.jobs.deinit(self.allocator);
            defer child_state.free_job_ids.deinit(self.allocator);

            var child_executor = Executor.init(self.allocator, &child_state);
            const result = child_executor.executeText(subshell.text, false) catch {
                std.posix.exit(1);
            };
            std.posix.exit(result.exit_code);
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

    fn builtinType(self: *Executor, argv: [][]u8, fd: std.posix.fd_t) !ExecResult {
        if (argv.len < 2) {
            try self.writeShellError("type: missing operand\n");
            return .{ .exit_code = 1 };
        }

        var exit_code: u8 = 0;
        for (argv[1..]) |name| {
            if (builtins.lookup(name)) |_| {
                var buf: [512]u8 = undefined;
                const rendered = try std.fmt.bufPrint(&buf, "{s} is a shell builtin\n", .{name});
                _ = try std.posix.write(fd, rendered);
                continue;
            }
            if (try self.resolveExecutablePath(&self.state.env, name)) |path| {
                defer self.allocator.free(path);
                var buf: [1024]u8 = undefined;
                const rendered = try std.fmt.bufPrint(&buf, "{s} is {s}\n", .{ name, path });
                _ = try std.posix.write(fd, rendered);
            } else {
                try self.writeShellErrorFmt("{s}: not found\n", .{name});
                exit_code = 1;
            }
        }
        return .{ .exit_code = exit_code };
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
        if (!self.state.interactive) {
            try self.writeShellError("jobs: interactive mode only\n");
            return .{ .exit_code = 1 };
        }
        jobs.poll(self.state);
        if (argv.len >= 2) {
            const job_id = jobs.parseJobSpec(self.state, argv[1]) orelse {
                try self.writeShellError("jobs: no such job\n");
                return .{ .exit_code = 1 };
            };
            const printed = try jobs.printJob(self.state, fd, job_id);
            if (!printed) {
                try self.writeShellError("jobs: no such job\n");
                return .{ .exit_code = 1 };
            }
        } else {
            try jobs.printJobs(self.state, fd);
        }
        return .{ .exit_code = 0 };
    }

    fn builtinHistory(self: *Executor, argv: [][]u8, fd: std.posix.fd_t) !ExecResult {
        if (!self.state.interactive) {
            try self.writeShellError("history: interactive mode only\n");
            return .{ .exit_code = 1 };
        }
        var start_index: usize = 0;
        if (argv.len >= 2) {
            const limit = std.fmt.parseUnsigned(usize, argv[1], 10) catch {
                try self.writeShellError("history: invalid limit\n");
                return .{ .exit_code = 1 };
            };
            if (limit < self.state.history.items.len) {
                start_index = self.state.history.items.len - limit;
            }
        }
        for (self.state.history.items[start_index..], start_index..) |line, idx| {
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
        return try self.waitForegroundJob(job.pgid, job.command, job.remaining_processes);
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
            .type => try self.builtinType(command.argv, std.posix.STDOUT_FILENO),
            .echo => try self.builtinEcho(command.argv, std.posix.STDOUT_FILENO),
            .history => try self.builtinHistory(command.argv, std.posix.STDOUT_FILENO),
            else => ExecResult{ .exit_code = 1 },
        };
        return result.exit_code;
    }

    fn resolveExecutablePath(self: *Executor, env_map: *const std.process.EnvMap, name: []const u8) !?[]u8 {
        if (std.mem.indexOfScalar(u8, name, '/')) |_| {
            std.posix.access(name, std.posix.X_OK) catch return null;
            return try self.allocator.dupe(u8, name);
        }

        const path_env = env_map.get("PATH") orelse "/usr/local/bin:/bin:/usr/bin";
        var it = std.mem.tokenizeScalar(u8, path_env, ':');
        while (it.next()) |segment| {
            const candidate = try std.fs.path.join(self.allocator, &.{ segment, name });
            errdefer self.allocator.free(candidate);
            std.posix.access(candidate, std.posix.X_OK) catch {
                self.allocator.free(candidate);
                continue;
            };
            return candidate;
        }
        return null;
    }

    fn writeShellError(self: *Executor, text: []const u8) !void {
        _ = self;
        _ = try std.posix.write(std.posix.STDERR_FILENO, text);
    }

    fn writeShellErrorFmt(self: *Executor, comptime fmt: []const u8, args: anytype) !void {
        var buf: [1024]u8 = undefined;
        const rendered = try std.fmt.bufPrint(&buf, fmt, args);
        try self.writeShellError(rendered);
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

        for (command.argv) |word| {
            const expanded_words = try expandWordForArgvRuntime(allocator, state, word);
            defer allocator.free(expanded_words);
            for (expanded_words) |expanded_word| try argv.append(allocator, expanded_word);
        }
        for (command.assignments) |assignment| {
            const expanded_value = try expandWordRuntime(allocator, state, assignment.value);
            try assignments.append(allocator, .{
                .name = try allocator.dupe(u8, assignment.name),
                .value = expanded_value,
            });
        }
        for (command.redirections) |redir| {
            const expanded_target = if (redir.target) |target| try expandWordRuntime(allocator, state, target) else null;
            try redirections.append(allocator, .{
                .kind = redir.kind,
                .target = expanded_target,
            });
        }
        return .{
            .argv = try argv.toOwnedSlice(allocator),
            .assignments = try assignments.toOwnedSlice(allocator),
            .redirections = try redirections.toOwnedSlice(allocator),
        };
    }

    fn makeEnvMap(self: ExpandedCommand, allocator: std.mem.Allocator, state: *ShellState) !std.process.EnvMap {
        var env_map = std.process.EnvMap.init(allocator);
        var it = state.env.iterator();
        while (it.next()) |entry| {
            try env_map.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        for (self.assignments) |assignment| {
            try env_map.put(assignment.name, assignment.value);
        }
        return env_map;
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

const ExpandedSubshell = struct {
    text: []u8,
    redirections: []ExpandedRedirection,

    fn init(allocator: std.mem.Allocator, state: *ShellState, command: ir.SubshellCommand) !ExpandedSubshell {
        var redirections = std.ArrayList(ExpandedRedirection).empty;
        errdefer {
            for (redirections.items) |redir| if (redir.target) |target| allocator.free(target);
            redirections.deinit(allocator);
        }
        for (command.redirections) |redir| {
            const expanded_target = if (redir.target) |target| try expandWordRuntime(allocator, state, target) else null;
            try redirections.append(allocator, .{ .kind = redir.kind, .target = expanded_target });
        }
        return .{ .text = try allocator.dupe(u8, command.text), .redirections = try redirections.toOwnedSlice(allocator) };
    }

    fn deinit(self: *ExpandedSubshell, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        for (self.redirections) |redir| if (redir.target) |target| allocator.free(target);
        allocator.free(self.redirections);
        self.* = undefined;
    }
};

const ExpandedCommandNode = union(enum) {
    simple: ExpandedCommand,
    subshell: ExpandedSubshell,

    fn deinit(self: *ExpandedCommandNode, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .simple => |*command| command.deinit(allocator),
            .subshell => |*command| command.deinit(allocator),
        }
        self.* = undefined;
    }
};

const ExpandedPipeline = struct {
    commands: []ExpandedCommandNode,
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
                        .stderr_truncate, .stderr_append => std.posix.STDERR_FILENO,
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
                    .stderr_truncate, .stderr_append => std.posix.STDERR_FILENO,
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
        .stderr_append => std.posix.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o644),
        .stderr_to_stdout => unreachable,
    };
}

const c = @cImport({
    @cInclude("sys/wait.h");
});

const RuntimeExpandedWord = struct {
    text: []u8,
    glob_allowed: bool,
};

fn expandWordRuntime(allocator: std.mem.Allocator, state: *ShellState, word: ir.Word) ![]u8 {
    const expanded = try expandWordRuntimeDetailed(allocator, state, word);
    return expanded.text;
}

fn expandWordForArgvRuntime(allocator: std.mem.Allocator, state: *ShellState, word: ir.Word) ![][]u8 {
    const expanded = try expandWordRuntimeDetailed(allocator, state, word);
    if (expanded.glob_allowed and hasGlobMeta(expanded.text)) {
        const matches = try expandGlobRuntime(allocator, expanded.text);
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

fn expandWordRuntimeDetailed(allocator: std.mem.Allocator, state: *ShellState, word: ir.Word) !RuntimeExpandedWord {
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
                const rendered = try runCommandSubstitutionInternal(allocator, state, data.text);
                defer allocator.free(rendered);
                try output.appendSlice(allocator, rendered);
            },
        }
    }

    return .{ .text = try output.toOwnedSlice(allocator), .glob_allowed = glob_allowed };
}

fn runCommandSubstitutionInternal(allocator: std.mem.Allocator, state: *ShellState, command_text: []const u8) ![]u8 {
    const pipe_fds = try std.posix.pipe();
    const pid = try std.posix.fork();
    if (pid == 0) {
        std.posix.close(pipe_fds[0]);
        std.posix.dup2(pipe_fds[1], std.posix.STDOUT_FILENO) catch {};
        std.posix.close(pipe_fds[1]);

        var child_state = state.*;
        child_state.interactive = false;
        child_state.should_exit = false;
        child_state.exit_code = 0;
        child_state.jobs = .empty;
        child_state.free_job_ids = .empty;
        defer child_state.jobs.deinit(allocator);
        defer child_state.free_job_ids.deinit(allocator);

        var child_executor = Executor.init(allocator, &child_state);
        if (child_executor.executeText(command_text, false)) |result| {
            std.posix.exit(result.exit_code);
        } else |_| {
            std.posix.exit(1);
        }
    }

    std.posix.close(pipe_fds[1]);
    const file = std.fs.File{ .handle = pipe_fds[0] };
    defer file.close();
    const raw = try file.readToEndAlloc(allocator, 256 * 1024);
    defer allocator.free(raw);

    var raw_status: c_int = 0;
    _ = c.waitpid(pid, &raw_status, 0);
    const status_bits: u32 = @bitCast(raw_status);
    if (wait_status.wifExited(status_bits)) {
        state.last_exit_status = wait_status.wexitStatus(status_bits);
    } else if (wait_status.wifSignaled(status_bits)) {
        state.last_exit_status = 128 + wait_status.wtermSig(status_bits);
    }

    const trimmed = std.mem.trimRight(u8, raw, "\r\n");
    return try allocator.dupe(u8, trimmed);
}

fn hasGlobMeta(text: []const u8) bool {
    return std.mem.indexOfAny(u8, text, "*?[") != null;
}

fn expandGlobRuntime(allocator: std.mem.Allocator, pattern: []const u8) ![][]u8 {
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
        if (!patternMatchesRuntime(file_pattern, entry.name)) continue;
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

fn patternMatchesRuntime(pattern: []const u8, text: []const u8) bool {
    return patternMatchesRecRuntime(pattern, text, 0, 0);
}

fn patternMatchesRecRuntime(pattern: []const u8, text: []const u8, pi: usize, ti: usize) bool {
    if (pi == pattern.len) return ti == text.len;
    if (pattern[pi] == '*') {
        var idx = ti;
        while (idx <= text.len) : (idx += 1) {
            if (patternMatchesRecRuntime(pattern, text, pi + 1, idx)) return true;
        }
        return false;
    }
    if (ti == text.len) return false;
    if (pattern[pi] == '?') return patternMatchesRecRuntime(pattern, text, pi + 1, ti + 1);
    if (pattern[pi] == '[') {
        var end = pi + 1;
        while (end < pattern.len and pattern[end] != ']') end += 1;
        if (end >= pattern.len) return false;
        const cls = pattern[pi + 1 .. end];
        if (!classMatchesRuntime(cls, text[ti])) return false;
        return patternMatchesRecRuntime(pattern, text, end + 1, ti + 1);
    }
    if (pattern[pi] != text[ti]) return false;
    return patternMatchesRecRuntime(pattern, text, pi + 1, ti + 1);
}

fn classMatchesRuntime(cls: []const u8, ch: u8) bool {
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

const LogicalOp = enum {
    and_and,
    or_or,
};

const LogicalChain = struct {
    segments: [][]u8,
    ops: []LogicalOp,

    fn deinit(self: *LogicalChain, allocator: std.mem.Allocator) void {
        for (self.segments) |segment| allocator.free(segment);
        allocator.free(self.segments);
        allocator.free(self.ops);
        self.* = undefined;
    }
};

const PreprocessedText = struct {
    text: []u8,
    temp_files: [][]u8,

    fn deinit(self: *PreprocessedText, allocator: std.mem.Allocator) void {
        for (self.temp_files) |path| {
            std.fs.deleteFileAbsolute(path) catch {};
            allocator.free(path);
        }
        allocator.free(self.temp_files);
        allocator.free(self.text);
        self.* = undefined;
    }
};

fn preprocessHeredocs(allocator: std.mem.Allocator, input: []const u8) !PreprocessedText {
    var lines = std.mem.splitScalar(u8, input, '\n');
    var rendered = std.ArrayList(u8).empty;
    var temp_files = std.ArrayList([]u8).empty;
    errdefer {
        for (temp_files.items) |path| allocator.free(path);
        temp_files.deinit(allocator);
        rendered.deinit(allocator);
    }

    var all_lines = std.ArrayList([]const u8).empty;
    defer all_lines.deinit(allocator);
    while (lines.next()) |line| try all_lines.append(allocator, line);

    var i: usize = 0;
    while (i < all_lines.items.len) : (i += 1) {
        const line = all_lines.items[i];
        if (std.mem.indexOf(u8, line, "<<")) |idx| {
            const prefix = line[0..idx];
            const tail = std.mem.trimLeft(u8, line[idx + 2 ..], " \t\r");
            const delim_end = blk: {
                if (std.mem.indexOfAny(u8, tail, " \t\r")) |end| break :blk end;
                break :blk tail.len;
            };
            const raw_delim = tail[0..delim_end];
            const suffix = std.mem.trimLeft(u8, tail[delim_end..], " \t\r");
            const delimiter = std.mem.trim(u8, raw_delim, "\"'");
            if (delimiter.len == 0) {
                try rendered.appendSlice(allocator, line);
                try rendered.append(allocator, '\n');
                continue;
            }

            var body = std.ArrayList(u8).empty;
            defer body.deinit(allocator);
            var j = i + 1;
            while (j < all_lines.items.len and !std.mem.eql(u8, all_lines.items[j], delimiter)) : (j += 1) {
                try body.appendSlice(allocator, all_lines.items[j]);
                try body.append(allocator, '\n');
            }
            if (j >= all_lines.items.len) {
                try rendered.appendSlice(allocator, line);
                try rendered.append(allocator, '\n');
                continue;
            }

            const temp_path = try std.fmt.allocPrint(allocator, "/tmp/zigsh-heredoc-{d}-{d}", .{ std.time.milliTimestamp(), temp_files.items.len });
            const file = try std.fs.createFileAbsolute(temp_path, .{ .truncate = true });
            defer file.close();
            try file.writeAll(body.items);
            try temp_files.append(allocator, temp_path);

            try rendered.appendSlice(allocator, prefix);
            try rendered.appendSlice(allocator, "< ");
            try rendered.appendSlice(allocator, temp_path);
            if (suffix.len != 0) {
                try rendered.append(allocator, ' ');
                try rendered.appendSlice(allocator, suffix);
            }
            try rendered.append(allocator, '\n');
            i = j;
        } else {
            try rendered.appendSlice(allocator, line);
            try rendered.append(allocator, '\n');
        }
    }

    return .{ .text = try rendered.toOwnedSlice(allocator), .temp_files = try temp_files.toOwnedSlice(allocator) };
}

fn splitLogicalChain(allocator: std.mem.Allocator, input: []const u8) !LogicalChain {
    var segments = std.ArrayList([]u8).empty;
    var ops = std.ArrayList(LogicalOp).empty;
    errdefer {
        for (segments.items) |segment| allocator.free(segment);
        segments.deinit(allocator);
        ops.deinit(allocator);
    }

    var start: usize = 0;
    var i: usize = 0;
    var in_single = false;
    var in_double = false;
    var command_depth: usize = 0;
    while (i < input.len) : (i += 1) {
        const ch = input[i];
        if (!in_double and ch == '\'') {
            in_single = !in_single;
            continue;
        }
        if (!in_single and ch == '"') {
            in_double = !in_double;
            continue;
        }
        if (!in_single and ch == '\\') {
            i += 1;
            continue;
        }
        if (!in_single and !in_double and ch == '$' and i + 1 < input.len and input[i + 1] == '(') {
            command_depth += 1;
            i += 1;
            continue;
        }
        if (!in_single and !in_double and ch == ')' and command_depth > 0) {
            command_depth -= 1;
            continue;
        }
        if (in_single or in_double or command_depth > 0) continue;
        if (i + 1 < input.len and input[i] == '&' and input[i + 1] == '&') {
            try segments.append(allocator, try allocator.dupe(u8, std.mem.trim(u8, input[start..i], " \t\r\n")));
            try ops.append(allocator, .and_and);
            i += 1;
            start = i + 1;
        } else if (i + 1 < input.len and input[i] == '|' and input[i + 1] == '|') {
            try segments.append(allocator, try allocator.dupe(u8, std.mem.trim(u8, input[start..i], " \t\r\n")));
            try ops.append(allocator, .or_or);
            i += 1;
            start = i + 1;
        }
    }
    try segments.append(allocator, try allocator.dupe(u8, std.mem.trim(u8, input[start..], " \t\r\n")));
    return .{ .segments = try segments.toOwnedSlice(allocator), .ops = try ops.toOwnedSlice(allocator) };
}
