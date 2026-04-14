const std = @import("std");

pub fn initShellSignalHandlers() void {
    const act = ignoreAction();
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
    std.posix.sigaction(std.posix.SIG.QUIT, &act, null);
    std.posix.sigaction(std.posix.SIG.TSTP, &act, null);
    std.posix.sigaction(std.posix.SIG.TTIN, &act, null);
    std.posix.sigaction(std.posix.SIG.TTOU, &act, null);
}

pub fn resetForChild() void {
    const act = defaultAction();
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
    std.posix.sigaction(std.posix.SIG.QUIT, &act, null);
    std.posix.sigaction(std.posix.SIG.TSTP, &act, null);
    std.posix.sigaction(std.posix.SIG.TTIN, &act, null);
    std.posix.sigaction(std.posix.SIG.TTOU, &act, null);
}

fn ignoreAction() std.posix.Sigaction {
    return .{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
}

fn defaultAction() std.posix.Sigaction {
    return .{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
}
