const std = @import("std");

pub const JobStatus = enum {
    running,
    stopped,
    done,
};

pub const Job = struct {
    id: usize,
    pgid: i32,
    command: []u8,
    status: JobStatus,
    remaining_processes: usize,
    last_status: ?u32 = null,
};

pub const ShellState = struct {
    allocator: std.mem.Allocator,
    env: std.process.EnvMap,
    cwd: []u8,
    history: std.ArrayList([]u8),
    loaded_history_count: usize,
    jobs: std.ArrayList(Job),
    free_job_ids: std.ArrayList(usize),
    last_exit_status: u8,
    interactive: bool,
    should_exit: bool,
    exit_code: u8,
    history_path: []u8,
    rc_path: []u8,
    shell_pgid: i32,
    prompt: []const u8,
    startup_loaded: bool,

    pub fn init(allocator: std.mem.Allocator, interactive: bool) !ShellState {
        var env = try std.process.getEnvMap(allocator);
        const cwd = try std.process.getCwdAlloc(allocator);
        const home = env.get("HOME") orelse ".";
        const history_path = try std.fs.path.join(allocator, &.{ home, ".zigsh_history" });
        const rc_path = try std.fs.path.join(allocator, &.{ home, ".zigshrc" });
        return .{
            .allocator = allocator,
            .env = env,
            .cwd = cwd,
            .history = .empty,
            .loaded_history_count = 0,
            .jobs = .empty,
            .free_job_ids = .empty,
            .last_exit_status = 0,
            .interactive = interactive,
            .should_exit = false,
            .exit_code = 0,
            .history_path = history_path,
            .rc_path = rc_path,
            .shell_pgid = 0,
            .prompt = "zigsh$ ",
            .startup_loaded = false,
        };
    }

    pub fn deinit(self: *ShellState) void {
        var it = self.env.iterator();
        while (it.next()) |entry| {
            _ = entry;
        }
        self.env.deinit();
        self.allocator.free(self.cwd);
        for (self.history.items) |line| self.allocator.free(line);
        self.history.deinit(self.allocator);
        for (self.jobs.items) |job| self.allocator.free(job.command);
        self.jobs.deinit(self.allocator);
        self.free_job_ids.deinit(self.allocator);
        self.allocator.free(self.history_path);
        self.allocator.free(self.rc_path);
        self.* = undefined;
    }

    pub fn setEnv(self: *ShellState, name: []const u8, value: []const u8) !void {
        try self.env.put(name, value);
    }

    pub fn unsetEnv(self: *ShellState, name: []const u8) void {
        self.env.remove(name);
    }

    pub fn refreshCwd(self: *ShellState) !void {
        self.allocator.free(self.cwd);
        self.cwd = try std.process.getCwdAlloc(self.allocator);
        try self.setEnv("PWD", self.cwd);
    }

    pub fn addHistory(self: *ShellState, line: []const u8) !void {
        if (!self.interactive) return;
        if (std.mem.trim(u8, line, " \t\r\n").len == 0) return;
        const duped = try self.allocator.dupe(u8, line);
        try self.history.append(self.allocator, duped);
    }

    pub fn markHistoryLoaded(self: *ShellState) void {
        self.loaded_history_count = self.history.items.len;
    }

    pub fn historyAppendEnabled(self: *const ShellState) bool {
        const value = self.env.get("HISTAPPEND") orelse return false;
        return std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "yes");
    }

    pub fn appendJob(self: *ShellState, pgid: i32, command: []const u8, status: JobStatus, remaining_processes: usize) !usize {
        const id = self.takeJobId();
        try self.jobs.append(self.allocator, .{
            .id = id,
            .pgid = pgid,
            .command = try self.allocator.dupe(u8, command),
            .status = status,
            .remaining_processes = remaining_processes,
            .last_status = null,
        });
        return id;
    }

    pub fn findJobById(self: *ShellState, id: usize) ?*Job {
        for (self.jobs.items) |*job| {
            if (job.id == id) return job;
        }
        return null;
    }

    pub fn findLatestJob(self: *ShellState) ?*Job {
        if (self.jobs.items.len == 0) return null;
        return &self.jobs.items[self.jobs.items.len - 1];
    }

    pub fn removeCompletedJobs(self: *ShellState) void {
        var i: usize = 0;
        while (i < self.jobs.items.len) {
            if (self.jobs.items[i].status == .done) {
                self.releaseJobId(self.jobs.items[i].id) catch {};
                self.allocator.free(self.jobs.items[i].command);
                _ = self.jobs.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    fn takeJobId(self: *ShellState) usize {
        if (self.free_job_ids.items.len == 0) return self.jobs.items.len + 1;

        var best_index: usize = 0;
        var best_value = self.free_job_ids.items[0];
        for (self.free_job_ids.items[1..], 1..) |value, idx| {
            if (value < best_value) {
                best_value = value;
                best_index = idx;
            }
        }
        _ = self.free_job_ids.orderedRemove(best_index);
        return best_value;
    }

    fn releaseJobId(self: *ShellState, id: usize) !void {
        for (self.free_job_ids.items) |existing| {
            if (existing == id) return;
        }
        try self.free_job_ids.append(self.allocator, id);
    }
};
