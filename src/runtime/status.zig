pub fn wifExited(status: u32) bool {
    return (status & 0x7f) == 0;
}

pub fn wexitStatus(status: u32) u8 {
    return @intCast((status & 0xff00) >> 8);
}

pub fn wtermSig(status: u32) u8 {
    return @intCast(status & 0x7f);
}

pub fn wifStopped(status: u32) bool {
    return (status & 0xff) == 0x7f;
}

pub fn wstopSig(status: u32) u8 {
    return wexitStatus(status);
}

pub fn wifSignaled(status: u32) bool {
    return ((status & 0xffff) -% 1) < 0xff;
}

pub fn wifContinued(status: u32) bool {
    return status == 0xffff;
}
