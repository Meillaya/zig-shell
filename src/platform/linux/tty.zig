const std = @import("std");
const c = @cImport({
    @cInclude("termios.h");
    @cInclude("unistd.h");
});

pub const RawMode = struct {
    original: c.struct_termios,
    active: bool,

    pub fn enable(fd: std.posix.fd_t) !RawMode {
        var original: c.struct_termios = undefined;
        if (c.tcgetattr(fd, &original) != 0) return error.Unexpected;
        var raw = original;
        raw.c_lflag &= ~@as(c.tcflag_t, c.ECHO | c.ICANON | c.IEXTEN | c.ISIG);
        raw.c_iflag &= ~@as(c.tcflag_t, c.IXON | c.ICRNL | c.BRKINT | c.INPCK | c.ISTRIP);
        raw.c_oflag &= ~@as(c.tcflag_t, c.OPOST);
        raw.c_cflag |= c.CS8;
        raw.c_cc[c.VMIN] = 1;
        raw.c_cc[c.VTIME] = 0;
        if (c.tcsetattr(fd, c.TCSAFLUSH, &raw) != 0) return error.Unexpected;
        return .{ .original = original, .active = true };
    }

    pub fn disable(self: *RawMode, fd: std.posix.fd_t) void {
        if (!self.active) return;
        _ = c.tcsetattr(fd, c.TCSAFLUSH, &self.original);
        self.active = false;
    }
};

pub fn isTty(fd: std.posix.fd_t) bool {
    return std.posix.isatty(fd);
}

pub fn takeTerminal(fd: std.posix.fd_t, pgid: i32) void {
    _ = c.tcsetpgrp(fd, pgid);
}
