const std = @import("std");
const ir = @import("../model/command_ir.zig");
pub const ParseError = @import("lexer.zig").ParseError;
const isAssignmentWord = @import("lexer.zig").isAssignmentWord;

pub const Parser = struct {
    allocator: std.mem.Allocator,
    input: []const u8,
    index: usize = 0,

    pub fn init(allocator: std.mem.Allocator, input: []const u8) Parser {
        return .{ .allocator = allocator, .input = input };
    }

    pub fn parseAll(self: *Parser) ParseError!ir.CommandList {
        var pipelines = std.ArrayList(ir.Pipeline).empty;
        errdefer {
            for (pipelines.items) |*pipeline| pipeline.deinit(self.allocator);
            pipelines.deinit(self.allocator);
        }

        while (true) {
            self.skipHorizontalSpace();
            self.skipCommandSeparators();
            self.skipHorizontalSpace();
            if (self.eof()) break;

            const start = self.index;
            var pipeline = try self.parsePipeline();
            pipeline.source = try self.allocator.dupe(u8, std.mem.trim(u8, self.input[start..self.index], " \t\r\n"));
            try pipelines.append(self.allocator, pipeline);

            self.skipHorizontalSpace();
            if (self.matchChar(';') or self.matchChar('\n')) {
                self.skipCommandSeparators();
            } else if (!self.eof()) {
                return error.UnexpectedToken;
            }
        }

        return .{ .pipelines = try pipelines.toOwnedSlice(self.allocator) };
    }

    fn parsePipeline(self: *Parser) ParseError!ir.Pipeline {
        var commands = std.ArrayList(ir.Command).empty;
        errdefer {
            for (commands.items) |*command| command.deinit(self.allocator);
            commands.deinit(self.allocator);
        }

        while (true) {
            const command = try self.parseCommand();
            switch (command) {
                .simple => |simple| if (simple.isEmpty()) return error.UnexpectedToken,
                .subshell => {},
                .function_def => {},
            }
            try commands.append(self.allocator, command);
            self.skipHorizontalSpace();
            if (self.peekTwo('&', '&') or self.peekTwo('|', '|')) return error.UnsupportedConstruct;
            if (!self.matchChar('|')) break;
            if (commands.items[commands.items.len - 1] == .function_def) return error.UnsupportedConstruct;
            self.skipHorizontalSpace();
        }

        self.skipHorizontalSpace();
        const background = self.matchChar('&');
        if (background) {
            for (commands.items) |command| {
                switch (command) {
                    .function_def => return error.UnsupportedConstruct,
                    else => {},
                }
            }
        }
        return .{
            .commands = try commands.toOwnedSlice(self.allocator),
            .background = background,
            .source = &.{},
        };
    }

    fn parseCommand(self: *Parser) ParseError!ir.Command {
        self.skipHorizontalSpace();
        if (try self.peekFunctionDefinition()) {
            return .{ .function_def = try self.parseFunctionDefinition() };
        }
        if (!self.eof() and self.input[self.index] == '(') {
            return .{ .subshell = try self.parseSubshellCommand() };
        }
        return .{ .simple = try self.parseSimpleCommand() };
    }

    fn peekFunctionDefinition(self: *Parser) !bool {
        var idx = self.index;
        if (idx >= self.input.len) return false;
        const first = self.input[idx];
        if (!(std.ascii.isAlphabetic(first) or first == '_')) return false;
        idx += 1;
        while (idx < self.input.len) : (idx += 1) {
            const ch = self.input[idx];
            if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) break;
        }
        if (idx + 1 >= self.input.len or self.input[idx] != '(' or self.input[idx + 1] != ')') return false;
        idx += 2;
        while (idx < self.input.len and (self.input[idx] == ' ' or self.input[idx] == '\t' or self.input[idx] == '\r')) : (idx += 1) {}
        return idx < self.input.len and self.input[idx] == '{';
    }

    fn parseFunctionDefinition(self: *Parser) ParseError!ir.FunctionDefCommand {
        const name_start = self.index;
        self.index += 1;
        while (self.index < self.input.len) : (self.index += 1) {
            const ch = self.input[self.index];
            if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) break;
        }
        const name = try self.allocator.dupe(u8, self.input[name_start..self.index]);

        std.debug.assert(self.input[self.index] == '(' and self.input[self.index + 1] == ')');
        self.index += 2;
        self.skipHorizontalSpace();
        std.debug.assert(self.input[self.index] == '{');
        self.index += 1;

        const body_start = self.index;
        var depth: usize = 1;
        var in_single = false;
        var in_double = false;
        while (!self.eof()) {
            const ch = self.input[self.index];
            if (!in_double and ch == '\'') {
                in_single = !in_single;
                self.index += 1;
                continue;
            }
            if (!in_single and ch == '"') {
                in_double = !in_double;
                self.index += 1;
                continue;
            }
            if (!in_single and ch == '\\') {
                self.index += 2;
                continue;
            }
            if (!in_single and !in_double and ch == '{') depth += 1;
            if (!in_single and !in_double and ch == '}') {
                depth -= 1;
                if (depth == 0) {
                    const body = try self.allocator.dupe(u8, std.mem.trim(u8, self.input[body_start..self.index], " \t\r\n"));
                    self.index += 1;
                    return .{ .name = name, .body = body };
                }
            }
            self.index += 1;
        }
        self.allocator.free(name);
        return error.UnexpectedToken;
    }

    fn parseSimpleCommand(self: *Parser) ParseError!ir.SimpleCommand {
        var assignments = std.ArrayList(ir.Assignment).empty;
        var argv = std.ArrayList(ir.Word).empty;
        var redirections = std.ArrayList(ir.Redirection).empty;
        errdefer {
            for (assignments.items) |*assignment| assignment.deinit(self.allocator);
            assignments.deinit(self.allocator);
            for (argv.items) |*word| word.deinit(self.allocator);
            argv.deinit(self.allocator);
            for (redirections.items) |*redir| redir.deinit(self.allocator);
            redirections.deinit(self.allocator);
        }

        var saw_non_assignment = false;
        while (true) {
            self.skipHorizontalSpace();
            if (self.eof()) break;
            const next = self.input[self.index];
            if (next == '\n' or next == ';' or next == '|' or next == '&') break;

            if (self.atRedirection()) {
                try redirections.append(self.allocator, try self.parseRedirection());
                continue;
            }

            var word = try self.parseWord();
            if (!saw_non_assignment and isAssignmentWord(&word)) {
                const pair = try self.assignmentFromWord(word);
                try assignments.append(self.allocator, pair);
            } else {
                saw_non_assignment = true;
                try argv.append(self.allocator, word);
            }
        }

        return .{
            .assignments = try assignments.toOwnedSlice(self.allocator),
            .argv = try argv.toOwnedSlice(self.allocator),
            .redirections = try redirections.toOwnedSlice(self.allocator),
        };
    }

    fn parseSubshellCommand(self: *Parser) ParseError!ir.SubshellCommand {
        std.debug.assert(self.input[self.index] == '(');
        self.index += 1;
        const start = self.index;
        var depth: usize = 1;
        var in_single = false;
        var in_double = false;

        while (!self.eof()) {
            const ch = self.input[self.index];
            if (!in_double and ch == '\'') {
                in_single = !in_single;
                self.index += 1;
                continue;
            }
            if (!in_single and ch == '"') {
                in_double = !in_double;
                self.index += 1;
                continue;
            }
            if (!in_single and ch == '\\') {
                self.index += 2;
                continue;
            }
            if (!in_single and ch == '(') depth += 1;
            if (!in_single and ch == ')') {
                depth -= 1;
                if (depth == 0) {
                    const text = try self.allocator.dupe(u8, std.mem.trim(u8, self.input[start..self.index], " \t\r\n"));
                    self.index += 1;
                    var redirections = std.ArrayList(ir.Redirection).empty;
                    errdefer {
                        self.allocator.free(text);
                        for (redirections.items) |*redir| redir.deinit(self.allocator);
                        redirections.deinit(self.allocator);
                    }
                    while (true) {
                        self.skipHorizontalSpace();
                        if (!self.atRedirection()) break;
                        try redirections.append(self.allocator, try self.parseRedirection());
                    }
                    return .{
                        .text = text,
                        .redirections = try redirections.toOwnedSlice(self.allocator),
                    };
                }
            }
            self.index += 1;
        }
        return error.UnexpectedToken;
    }

    fn assignmentFromWord(self: *Parser, word_in: ir.Word) !ir.Assignment {
        var word = word_in;
        var raw = std.ArrayList(u8).empty;
        defer raw.deinit(self.allocator);
        for (word.pieces) |piece| {
            switch (piece) {
                .literal => |piece_data| {
                    if (piece_data.quoted) unreachable;
                    try raw.appendSlice(self.allocator, piece_data.text);
                },
                .variable, .command_substitution => unreachable,
            }
        }
        const eq = std.mem.indexOfScalar(u8, raw.items, '=') orelse unreachable;
        const name = try self.allocator.dupe(u8, raw.items[0..eq]);

        var pieces = std.ArrayList(ir.WordPiece).empty;
        errdefer pieces.deinit(self.allocator);
        if (eq + 1 < raw.items.len) {
            try pieces.append(self.allocator, .{ .literal = .{ .text = try self.allocator.dupe(u8, raw.items[eq + 1 ..]), .quoted = false } });
        }
        const value_word = ir.Word{ .pieces = try pieces.toOwnedSlice(self.allocator) };
        word.deinit(self.allocator);
        return .{ .name = name, .value = value_word };
    }

    fn parseRedirection(self: *Parser) ParseError!ir.Redirection {
        if (self.matchString("2>>")) {
            self.skipHorizontalSpace();
            return .{ .kind = .stderr_append, .target = try self.parseWord() };
        }
        if (self.matchString("2>&1")) return .{ .kind = .stderr_to_stdout, .target = null };
        if (self.matchString("2>")) {
            self.skipHorizontalSpace();
            return .{ .kind = .stderr_truncate, .target = try self.parseWord() };
        }
        if (self.matchString(">>")) {
            self.skipHorizontalSpace();
            return .{ .kind = .stdout_append, .target = try self.parseWord() };
        }
        if (self.matchString(">")) {
            self.skipHorizontalSpace();
            return .{ .kind = .stdout_truncate, .target = try self.parseWord() };
        }
        if (self.matchString("<")) {
            self.skipHorizontalSpace();
            return .{ .kind = .stdin_file, .target = try self.parseWord() };
        }
        return error.UnexpectedToken;
    }

    fn parseWord(self: *Parser) ParseError!ir.Word {
        var pieces = std.ArrayList(ir.WordPiece).empty;
        errdefer {
            for (pieces.items) |piece| switch (piece) {
                .literal => |data| self.allocator.free(data.text),
                .variable => |data| self.allocator.free(data.text),
                .command_substitution => |data| self.allocator.free(data.text),
            };
            pieces.deinit(self.allocator);
        }

        var literal = std.ArrayList(u8).empty;
        defer literal.deinit(self.allocator);

        while (!self.eof()) {
            const ch = self.input[self.index];
            if (ch == ' ' or ch == '\t' or ch == '\n' or ch == ';' or ch == '|' or ch == '&') break;
            if (self.atRedirection()) break;
            if (ch == '`') return error.UnsupportedConstruct;
            if (ch == '(' or ch == ')') return error.UnsupportedConstruct;

            switch (ch) {
                '\\' => {
                    self.index += 1;
                    if (self.eof()) break;
                    try literal.append(self.allocator, self.input[self.index]);
                    self.index += 1;
                },
                '\'' => {
                    try self.flushLiteral(&pieces, &literal);
                    self.index += 1;
                    const start = self.index;
                    while (!self.eof() and self.input[self.index] != '\'') self.index += 1;
                    if (self.eof()) return error.UnterminatedSingleQuote;
                    const slice = self.input[start..self.index];
                    try pieces.append(self.allocator, .{ .literal = .{ .text = try self.allocator.dupe(u8, slice), .quoted = true } });
                    self.index += 1;
                },
                '"' => {
                    self.index += 1;
                    while (!self.eof()) {
                        const inner = self.input[self.index];
                        if (inner == '"') {
                            self.index += 1;
                            break;
                        }
                        if (inner == '\\') {
                            self.index += 1;
                            if (self.eof()) return error.UnterminatedDoubleQuote;
                            try literal.append(self.allocator, self.input[self.index]);
                            self.index += 1;
                            continue;
                        }
                        if (inner == '$' and self.peekOffset(1) == '(') {
                            try self.flushLiteralQuoted(&pieces, &literal, true);
                            try pieces.append(self.allocator, .{ .command_substitution = .{ .text = try self.parseCommandSubstitution(), .quoted = true } });
                            continue;
                        }
                        if (inner == '$') {
                            try self.flushLiteralQuoted(&pieces, &literal, true);
                            try pieces.append(self.allocator, .{ .variable = .{ .text = try self.parseVariableName(), .quoted = true } });
                            continue;
                        }
                        try literal.append(self.allocator, inner);
                        self.index += 1;
                    }
                    if (self.eof() and (self.input.len == 0 or self.input[self.input.len - 1] != '"')) {
                        return error.UnterminatedDoubleQuote;
                    }
                },
                '$' => {
                    try self.flushLiteral(&pieces, &literal);
                    if (self.peekOffset(1) == '(') {
                        try pieces.append(self.allocator, .{ .command_substitution = .{ .text = try self.parseCommandSubstitution(), .quoted = false } });
                    } else {
                        try pieces.append(self.allocator, .{ .variable = .{ .text = try self.parseVariableName(), .quoted = false } });
                    }
                },
                else => {
                    try literal.append(self.allocator, ch);
                    self.index += 1;
                },
            }
        }

        try self.flushLiteral(&pieces, &literal);
        if (pieces.items.len == 0) return error.UnexpectedToken;
        return .{ .pieces = try pieces.toOwnedSlice(self.allocator) };
    }

    fn parseVariableName(self: *Parser) ![]const u8 {
        std.debug.assert(self.input[self.index] == '$');
        self.index += 1;
        if (self.eof()) return self.allocator.dupe(u8, "");
        if (self.matchChar('{')) {
            const start = self.index;
            while (!self.eof() and self.input[self.index] != '}') self.index += 1;
            if (self.eof()) return error.UnexpectedToken;
            const name = try self.allocator.dupe(u8, self.input[start..self.index]);
            self.index += 1;
            return name;
        }
        const start = self.index;
        if (!(std.ascii.isAlphabetic(self.input[self.index]) or self.input[self.index] == '_' or std.ascii.isDigit(self.input[self.index]) or self.input[self.index] == '?')) {
            return self.allocator.dupe(u8, "");
        }
        if (self.input[self.index] == '?') {
            self.index += 1;
            return self.allocator.dupe(u8, "?");
        }
        while (!self.eof()) {
            const ch = self.input[self.index];
            if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) break;
            self.index += 1;
        }
        return self.allocator.dupe(u8, self.input[start..self.index]);
    }

    fn parseCommandSubstitution(self: *Parser) ![]const u8 {
        std.debug.assert(self.input[self.index] == '$');
        self.index += 1;
        std.debug.assert(self.input[self.index] == '(');
        self.index += 1;
        const start = self.index;
        var depth: usize = 1;
        var in_single = false;
        var in_double = false;
        while (!self.eof()) {
            const ch = self.input[self.index];
            if (!in_double and ch == '\'') {
                in_single = !in_single;
                self.index += 1;
                continue;
            }
            if (!in_single and ch == '"') {
                in_double = !in_double;
                self.index += 1;
                continue;
            }
            if (!in_single and ch == '\\') {
                self.index += 2;
                continue;
            }
            if (!in_single and ch == '(') depth += 1;
            if (!in_single and ch == ')') {
                depth -= 1;
                if (depth == 0) {
                    const text = try self.allocator.dupe(u8, self.input[start..self.index]);
                    self.index += 1;
                    return text;
                }
            }
            self.index += 1;
        }
        return error.UnexpectedToken;
    }

    fn flushLiteral(self: *Parser, pieces: *std.ArrayList(ir.WordPiece), literal: *std.ArrayList(u8)) !void {
        if (literal.items.len == 0) return;
        try pieces.append(self.allocator, .{ .literal = .{ .text = try self.allocator.dupe(u8, literal.items), .quoted = false } });
        literal.clearRetainingCapacity();
    }

    fn flushLiteralQuoted(self: *Parser, pieces: *std.ArrayList(ir.WordPiece), literal: *std.ArrayList(u8), quoted: bool) !void {
        if (literal.items.len == 0) return;
        try pieces.append(self.allocator, .{ .literal = .{ .text = try self.allocator.dupe(u8, literal.items), .quoted = quoted } });
        literal.clearRetainingCapacity();
    }

    fn atRedirection(self: *Parser) bool {
        return self.peekString("2>>") or self.peekString("2>&1") or self.peekString("2>") or self.peekString(">>") or self.peekString(">") or self.peekString("<");
    }

    fn skipHorizontalSpace(self: *Parser) void {
        while (!self.eof()) {
            const ch = self.input[self.index];
            if (ch != ' ' and ch != '\t' and ch != '\r') break;
            self.index += 1;
        }
    }

    fn skipCommandSeparators(self: *Parser) void {
        while (!self.eof()) {
            const ch = self.input[self.index];
            if (ch != '\n' and ch != ';') break;
            self.index += 1;
        }
    }

    fn eof(self: *Parser) bool {
        return self.index >= self.input.len;
    }

    fn matchChar(self: *Parser, ch: u8) bool {
        if (self.eof() or self.input[self.index] != ch) return false;
        self.index += 1;
        return true;
    }

    fn matchString(self: *Parser, text: []const u8) bool {
        if (!self.peekString(text)) return false;
        self.index += text.len;
        return true;
    }

    fn peekString(self: *Parser, text: []const u8) bool {
        return self.index + text.len <= self.input.len and std.mem.eql(u8, self.input[self.index .. self.index + text.len], text);
    }

    fn peekTwo(self: *Parser, a: u8, b: u8) bool {
        return self.index + 1 < self.input.len and self.input[self.index] == a and self.input[self.index + 1] == b;
    }

    fn peekOffset(self: *Parser, offset: usize) u8 {
        if (self.index + offset >= self.input.len) return 0;
        return self.input[self.index + offset];
    }
};

pub fn parse(allocator: std.mem.Allocator, input: []const u8) ParseError!ir.CommandList {
    var parser = Parser.init(allocator, input);
    return try parser.parseAll();
}

test "parse pipeline and redirection" {
    var cmd_list = try parse(std.testing.allocator, "echo hi | grep h > out.txt\n");
    defer cmd_list.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), cmd_list.pipelines.len);
    try std.testing.expectEqual(@as(usize, 2), cmd_list.pipelines[0].commands.len);
    try std.testing.expectEqual(@as(usize, 1), cmd_list.pipelines[0].commands[1].simple.redirections.len);
}

test "parse stderr append redirection" {
    var cmd_list = try parse(std.testing.allocator, "echo hi 2>> err.txt\n");
    defer cmd_list.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), cmd_list.pipelines[0].commands[0].simple.redirections.len);
    try std.testing.expectEqual(ir.RedirectionKind.stderr_append, cmd_list.pipelines[0].commands[0].simple.redirections[0].kind);
}

test "parse command substitution" {
    var cmd_list = try parse(std.testing.allocator, "echo $(whoami)\n");
    defer cmd_list.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), cmd_list.pipelines.len);
    try std.testing.expectEqual(@as(usize, 1), cmd_list.pipelines[0].commands.len);
    try std.testing.expectEqual(@as(usize, 2), cmd_list.pipelines[0].commands[0].simple.argv.len);
}
