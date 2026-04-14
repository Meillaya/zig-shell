const std = @import("std");
const signals = @import("signals.zig");

pub const SpawnPlan = struct {
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    env_map: *const std.process.EnvMap,
    stdin_fd: ?std.posix.fd_t = null,
    stdout_fd: ?std.posix.fd_t = null,
    stderr_fd: ?std.posix.fd_t = null,
    process_group: ?i32 = null,
    cwd: ?[]const u8 = null,
};

pub fn spawn(plan: SpawnPlan) !i32 {
    var arena_state = std.heap.ArenaAllocator.init(plan.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var argv_z = try arena.alloc(?[*:0]u8, plan.argv.len + 1);
    for (plan.argv, 0..) |arg, idx| {
        argv_z[idx] = (try arena.dupeZ(u8, arg)).ptr;
    }
    argv_z[plan.argv.len] = null;

    const envp = try std.process.createNullDelimitedEnvMap(arena, plan.env_map);
    const pid = try std.posix.fork();
    if (pid == 0) {
        if (plan.process_group) |pgid| {
            std.posix.setpgid(0, if (pgid == 0) 0 else pgid) catch {};
        }
        signals.resetForChild();
        if (plan.cwd) |cwd| std.posix.chdir(cwd) catch {};
        if (plan.stdin_fd) |fd| if (fd != std.posix.STDIN_FILENO) std.posix.dup2(fd, std.posix.STDIN_FILENO) catch {};
        if (plan.stdout_fd) |fd| if (fd != std.posix.STDOUT_FILENO) std.posix.dup2(fd, std.posix.STDOUT_FILENO) catch {};
        if (plan.stderr_fd) |fd| if (fd != std.posix.STDERR_FILENO) std.posix.dup2(fd, std.posix.STDERR_FILENO) catch {};
        std.posix.execvpeZ(argv_z[0].?, @ptrCast(argv_z.ptr), envp.ptr) catch {
            _ = std.posix.write(std.posix.STDERR_FILENO, "exec failed\n") catch {};
            std.posix.exit(127);
        };
        unreachable;
    }

    if (plan.process_group) |pgid| {
        std.posix.setpgid(pid, if (pgid == 0) pid else pgid) catch {};
    }
    return pid;
}
