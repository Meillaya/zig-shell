const std = @import("std");

pub const WordPiece = union(enum) {
    literal: []const u8,
    variable: []const u8,
};

pub const Word = struct {
    pieces: []WordPiece,

    pub fn initOwned(allocator: std.mem.Allocator, pieces_in: []const WordPiece) !Word {
        var pieces = try allocator.alloc(WordPiece, pieces_in.len);
        for (pieces_in, 0..) |piece, i| {
            pieces[i] = switch (piece) {
                .literal => |value| .{ .literal = try allocator.dupe(u8, value) },
                .variable => |value| .{ .variable = try allocator.dupe(u8, value) },
            };
        }
        return .{ .pieces = pieces };
    }

    pub fn deinit(self: *Word, allocator: std.mem.Allocator) void {
        for (self.pieces) |piece| {
            switch (piece) {
                .literal => |value| allocator.free(value),
                .variable => |value| allocator.free(value),
            }
        }
        allocator.free(self.pieces);
        self.* = undefined;
    }
};

pub const Assignment = struct {
    name: []const u8,
    value: Word,

    pub fn deinit(self: *Assignment, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.value.deinit(allocator);
        self.* = undefined;
    }
};

pub const RedirectionKind = enum {
    stdin_file,
    stdout_truncate,
    stdout_append,
    stderr_truncate,
    stderr_append,
    stderr_to_stdout,
};

pub const Redirection = struct {
    kind: RedirectionKind,
    target: ?Word = null,

    pub fn deinit(self: *Redirection, allocator: std.mem.Allocator) void {
        if (self.target) |*target| target.deinit(allocator);
        self.* = undefined;
    }
};

pub const SimpleCommand = struct {
    assignments: []Assignment,
    argv: []Word,
    redirections: []Redirection,

    pub fn deinit(self: *SimpleCommand, allocator: std.mem.Allocator) void {
        for (self.assignments) |*assignment| assignment.deinit(allocator);
        allocator.free(self.assignments);
        for (self.argv) |*word| word.deinit(allocator);
        allocator.free(self.argv);
        for (self.redirections) |*redir| redir.deinit(allocator);
        allocator.free(self.redirections);
        self.* = undefined;
    }

    pub fn isEmpty(self: SimpleCommand) bool {
        return self.assignments.len == 0 and self.argv.len == 0 and self.redirections.len == 0;
    }
};

pub const Pipeline = struct {
    commands: []SimpleCommand,
    background: bool,
    source: []const u8,

    pub fn deinit(self: *Pipeline, allocator: std.mem.Allocator) void {
        for (self.commands) |*command| command.deinit(allocator);
        allocator.free(self.commands);
        allocator.free(self.source);
        self.* = undefined;
    }
};

pub const CommandList = struct {
    pipelines: []Pipeline,

    pub fn deinit(self: *CommandList, allocator: std.mem.Allocator) void {
        for (self.pipelines) |*pipeline| pipeline.deinit(allocator);
        allocator.free(self.pipelines);
        self.* = undefined;
    }
};
