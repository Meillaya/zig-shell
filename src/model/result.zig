pub const ExecResult = struct {
    exit_code: u8 = 0,
    should_exit_shell: bool = false,
};
