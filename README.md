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
- redirection: `>`, `>>`, `<`, `2>`, `2>&1`
- background jobs with `&`
- env expansion: `$VAR`, `${VAR}`
- single quotes, double quotes, backslash escaping
- startup config via `~/.zigshrc`
- history persistence via `~/.zigsh_history`
- basic command/path completion
- non-interactive script execution

### Not supported
- `&&`, `||`
- command substitution
- heredocs
- shell functions / subshells
- globbing
- portability beyond Linux-first behavior
