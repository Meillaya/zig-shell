const std = @import("std");
const ir = @import("../model/command_ir.zig");

pub const ParseError = std.mem.Allocator.Error || error{
    UnexpectedToken,
    UnterminatedSingleQuote,
    UnterminatedDoubleQuote,
    MissingRedirectionTarget,
    UnsupportedConstruct,
};

pub fn isAssignmentWord(word: *const ir.Word) bool {
    if (word.pieces.len == 0) return false;
    if (word.pieces[0] != .literal) return false;

    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    for (word.pieces) |piece| {
        switch (piece) {
            .literal => |piece_data| {
                if (piece_data.quoted) return false;
                fbs.writer().writeAll(piece_data.text) catch return false;
            },
            .variable => return false,
            .command_substitution => return false,
        }
    }
    const data = fbs.getWritten();
    const eq_index = std.mem.indexOfScalar(u8, data, '=') orelse return false;
    if (eq_index == 0) return false;
    const name = data[0..eq_index];
    if (!(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name[1..]) |ch| {
        if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) return false;
    }
    return true;
}
