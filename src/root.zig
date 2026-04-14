pub const app = @import("app.zig");
pub const ShellApp = app.ShellApp;
pub const model = struct {
    pub const command_ir = @import("model/command_ir.zig");
    pub const shell_state = @import("model/shell_state.zig");
    pub const result = @import("model/result.zig");
};
pub const parse = struct {
    pub const lexer = @import("parse/lexer.zig");
    pub const parser = @import("parse/parser.zig");
};
pub const expand = struct {
    pub const expander = @import("expand/expander.zig");
};
pub const runtime = struct {
    pub const builtins = @import("runtime/builtins.zig");
    pub const executor = @import("runtime/executor.zig");
    pub const jobs = @import("runtime/jobs.zig");
    pub const status = @import("runtime/status.zig");
};
pub const platform = struct {
    pub const linux = struct {
        pub const process = @import("platform/linux/process.zig");
        pub const tty = @import("platform/linux/tty.zig");
        pub const signals = @import("platform/linux/signals.zig");
    };
};
pub const input = struct {
    pub const editor = @import("input/editor.zig");
};
pub const config = @import("config/config.zig");
pub const script = @import("script/script.zig");
pub const test_support = @import("test_support/harness.zig");

test {
    _ = @import("parse/parser.zig");
    _ = @import("expand/expander.zig");
    _ = @import("runtime/builtins.zig");
    _ = @import("test_support/harness.zig");
}
