const std = @import("std");
const ShellState = @import("model/shell_state.zig").ShellState;
const Executor = @import("runtime/executor.zig").Executor;
const config = @import("config/config.zig");
const editor = @import("input/editor.zig");
const jobs = @import("runtime/jobs.zig");
const signals = @import("platform/linux/signals.zig");
const tty = @import("platform/linux/tty.zig");
const script = @import("script/script.zig");

pub const ShellApp = struct {
    allocator: std.mem.Allocator,
    state: ShellState,

    pub fn init(allocator: std.mem.Allocator) !ShellApp {
        const interactive = tty.isTty(std.posix.STDIN_FILENO) and tty.isTty(std.posix.STDOUT_FILENO);
        return .{
            .allocator = allocator,
            .state = try ShellState.init(allocator, interactive),
        };
    }

    pub fn deinit(self: *ShellApp) void {
        config.saveHistory(&self.state) catch {};
        self.state.deinit();
    }

    pub fn run(self: *ShellApp) !void {
        const args = try std.process.argsAlloc(self.allocator);
        defer std.process.argsFree(self.allocator, args);

        if (self.state.interactive) {
            signals.initShellSignalHandlers();
            self.state.shell_pgid = @intCast(std.os.linux.getpid());
            std.posix.setpgid(0, 0) catch {};
            tty.takeTerminal(std.posix.STDIN_FILENO, self.state.shell_pgid);
            try config.loadHistory(&self.state);
            try self.loadStartupConfig();
            try self.runInteractive();
            return;
        }

        if (args.len >= 2) {
            const contents = try script.readFile(self.allocator, args[1]);
            defer self.allocator.free(contents);
            _ = try self.executeText(contents, false);
            return;
        }

        const stdin_contents = try std.fs.File.stdin().readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(stdin_contents);
        _ = try self.executeText(stdin_contents, false);
    }

    pub fn executeText(self: *ShellApp, text: []const u8, record_history: bool) !u8 {
        var executor = Executor.init(self.allocator, &self.state);
        const result = try executor.executeText(text, record_history);
        self.state.last_exit_status = result.exit_code;
        if (result.should_exit_shell) self.state.should_exit = true;
        return result.exit_code;
    }

    pub fn loadStartupConfigForTest(self: *ShellApp) !void {
        try self.loadStartupConfig();
    }

    fn loadStartupConfig(self: *ShellApp) !void {
        const contents = std.fs.cwd().readFileAlloc(self.allocator, self.state.rc_path, 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer self.allocator.free(contents);
        _ = try self.executeText(contents, false);
        self.state.startup_loaded = true;
    }

    fn runInteractive(self: *ShellApp) !void {
        while (!self.state.should_exit) {
            jobs.poll(&self.state);
            self.state.removeCompletedJobs();
            const line = (try editor.readLine(self.allocator, &self.state)) orelse break;
            defer self.allocator.free(line);
            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            if (trimmed.len == 0) continue;
            _ = try self.executeText(trimmed, true);
        }
    }
};
