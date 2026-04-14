# zig-shell

A small Linux-first shell written in Zig.

## Setup
- Install Zig 0.15.2
- Install Python 3

## Build
```bash
zig build
```

## Run
```bash
zig-out/bin/zig-shell
# or
zig build run
```

## Test
```bash
zig build test
zig build pty-smoke
python3 scripts/generate_interactive_transcript.py zig-out/bin/zig-shell
```

## Currently supported

### Builtins
- `cd`
- `exit`
- `pwd`
- `type`
- `export`
- `unset`
- `echo`
- `jobs`
- `fg`
- `bg`
- `history`
- `source` / `.`

### Command features
- external command execution via `PATH`
- pipelines with `|`
- child-safe builtins in pipelines (`echo`, `pwd`, `history`, `type`)
- parent-mutating builtins stay rejected in pipeline/background contexts
- redirection: `>`, `>>`, `<`, `2>`, `2>>`, `2>&1`
- background jobs with `&`
- single-job lookup via `jobs %n`
- env expansion: `$VAR`, `${VAR}`
- single quotes, double quotes, backslash escaping
- startup config via `~/.zigshrc`
- history persistence via `~/.zigsh_history`
- history output limiting via `history N`
- append-on-exit history mode via `HISTAPPEND=1`
- basic command/path completion
- non-interactive script execution

### Not supported
- `&&`, `||`
- command substitution
- heredocs
- shell functions / subshells
- globbing
- portability beyond Linux-first behavior

## Useful web references
- [Zig 0.15.2 language reference](https://ziglang.org/documentation/0.15.2/)
- [Zig 0.15.2 standard library docs](https://ziglang.org/documentation/0.15.2/std/)
- [waitpid(2) — child lifecycle and reap semantics](https://man7.org/linux/man-pages/man2/waitpid.2.html)
- [setpgid(2) — process groups and job control](https://man7.org/linux/man-pages/man2/setpgid.2.html)
- [tcsetpgrp(3) and terminal foreground control](https://man7.org/linux/man-pages/man3/tcsetpgrp.3.html)
- [termios(3) — terminal mode handling](https://man7.org/linux/man-pages/man3/termios.3.html)
