const std = @import("std");
const ShellState = @import("../model/shell_state.zig").ShellState;
const JobStatus = @import("../model/shell_state.zig").JobStatus;
const status = @import("status.zig");

const WNOHANG: c_int = 1;
const WUNTRACED: c_int = 2;
const WCONTINUED: c_int = 8;

pub fn poll(state: *ShellState) void {
    for (state.jobs.items) |*job| {
        while (true) {
            var raw_status: c_int = 0;
            const pid = c.waitpid(-job.pgid, &raw_status, WNOHANG | WUNTRACED | WCONTINUED);
            if (pid <= 0) break;
            const st: u32 = @bitCast(raw_status);
            job.last_status = st;
            if (status.wifStopped(st)) {
                job.status = .stopped;
            } else if (status.wifContinued(st)) {
                job.status = .running;
            } else if (status.wifExited(st) or status.wifSignaled(st)) {
                if (job.remaining_processes > 0) job.remaining_processes -= 1;
                if (job.remaining_processes == 0) {
                    job.status = .done;
                } else {
                    job.status = .running;
                }
            }
        }
    }
}

pub fn printJobs(state: *ShellState, fd: std.posix.fd_t) !void {
    for (state.jobs.items) |job| {
        const label = switch (job.status) {
            .running => "Running",
            .stopped => "Stopped",
            .done => "Done",
        };
        var buf: [1024]u8 = undefined;
        const rendered = try std.fmt.bufPrint(&buf, "[{d}] {s}\t{s}\n", .{ job.id, label, job.command });
        _ = try std.posix.write(fd, rendered);
    }
}

pub fn printJob(state: *ShellState, fd: std.posix.fd_t, id: usize) !bool {
    const job = state.findJobById(id) orelse return false;
    const label = switch (job.status) {
        .running => "Running",
        .stopped => "Stopped",
        .done => "Done",
    };
    var buf: [1024]u8 = undefined;
    const rendered = try std.fmt.bufPrint(&buf, "[{d}] {s}\t{s}\n", .{ job.id, label, job.command });
    _ = try std.posix.write(fd, rendered);
    return true;
}

pub fn parseJobSpec(state: *ShellState, text: ?[]const u8) ?usize {
    if (text == null) {
        if (state.findLatestJob()) |job| return job.id;
        return null;
    }
    const raw = text.?;
    const trimmed = if (raw.len > 0 and raw[0] == '%') raw[1..] else raw;
    return std.fmt.parseUnsigned(usize, trimmed, 10) catch null;
}

const c = @cImport({
    @cInclude("sys/wait.h");
});
