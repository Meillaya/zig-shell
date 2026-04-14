const std = @import("std");

pub const Builtin = enum {
    cd,
    exit,
    pwd,
    @"export",
    unset,
    echo,
    jobs,
    fg,
    bg,
    history,
    source,
};

pub const names = [_][]const u8{
    "cd",
    "exit",
    "pwd",
    "export",
    "unset",
    "echo",
    "jobs",
    "fg",
    "bg",
    "history",
    "source",
    ".",
};

pub fn lookup(name: []const u8) ?Builtin {
    if (std.mem.eql(u8, name, "cd")) return .cd;
    if (std.mem.eql(u8, name, "exit")) return .exit;
    if (std.mem.eql(u8, name, "pwd")) return .pwd;
    if (std.mem.eql(u8, name, "export")) return .@"export";
    if (std.mem.eql(u8, name, "unset")) return .unset;
    if (std.mem.eql(u8, name, "echo")) return .echo;
    if (std.mem.eql(u8, name, "jobs")) return .jobs;
    if (std.mem.eql(u8, name, "fg")) return .fg;
    if (std.mem.eql(u8, name, "bg")) return .bg;
    if (std.mem.eql(u8, name, "history")) return .history;
    if (std.mem.eql(u8, name, "source") or std.mem.eql(u8, name, ".")) return .source;
    return null;
}

pub fn isParentOnly(builtin: Builtin) bool {
    return switch (builtin) {
        .cd, .exit, .@"export", .unset, .source, .jobs, .fg, .bg => true,
        .pwd, .echo, .history => false,
    };
}

pub fn isInteractiveOnly(builtin: Builtin) bool {
    return switch (builtin) {
        .jobs, .fg, .bg, .history => true,
        else => false,
    };
}
