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
- conditionals with `&&` and `||`
- bounded subshell groups `( ... )`
- bounded shell functions with `name() { ... }`
- child-safe builtins in pipelines (`echo`, `pwd`, `history`, `type`)
- parent-mutating builtins stay rejected in pipeline/background contexts
- redirection: `>`, `>>`, `<`, `2>`, `2>>`, `2>&1`
- background jobs with `&`
- single-job lookup via `jobs %n`
- env expansion: `$VAR`, `${VAR}`
- command substitution: `$(...)` through the shell’s internal execution path (bounded initial support)
- globbing: `*`, `?`, `[a-z]` style classes
- heredocs with `<<DELIM`
- single quotes, double quotes, backslash escaping
- startup config via `~/.zigshrc`
- prompt override via `PS1`
- history persistence via `~/.zigsh_history`
- history output limiting via `history N`
- append-on-exit history mode via `HISTAPPEND=1`
- basic command/path completion
- cursor-aware line editing (left/right movement, insertion, backspace at cursor)
- non-interactive script execution

### Intentionally bounded
- shell functions support one definition form only: `name() { ... }`
- function bodies are stored as bounded text and re-parsed on call
- subshell support is bounded, not full compound-command parity
- command substitution is bounded and intentionally conservative
- heredocs are intentionally narrow (no tab-strip mode)
- unmatched globs remain literal
- history/completion UX polish is still rough

### Not supported
- alternate function-definition syntax forms
- backtick command substitution
- brace expansion
- full general shell grammar parity
- full POSIX parity
- portability beyond Linux-first behavior

## Useful web references
- [Zig 0.15.2 language reference](https://ziglang.org/documentation/0.15.2/)
- [Zig 0.15.2 standard library docs](https://ziglang.org/documentation/0.15.2/std/)
- [waitpid(2) — child lifecycle and reap semantics](https://man7.org/linux/man-pages/man2/waitpid.2.html)
- [setpgid(2) — process groups and job control](https://man7.org/linux/man-pages/man2/setpgid.2.html)
- [tcsetpgrp(3) and terminal foreground control](https://man7.org/linux/man-pages/man3/tcsetpgrp.3.html)
- [termios(3) — terminal mode handling](https://man7.org/linux/man-pages/man3/termios.3.html)
