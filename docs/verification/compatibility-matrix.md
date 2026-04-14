# Compatibility Matrix

This project is a Linux-first, bash-like shell with bounded semantics. It is **not** full POSIX sh compatibility.

## Supported (bounded)
- pipelines with `|`
- conditionals with `&&` and `||`
- subshell groups `( ... )` in bounded forms
- variable expansion: `$VAR`, `${VAR}`
- command substitution: `$(...)` through the shell's internal execution path (bounded initial support)
- globbing: `*`, `?`, and bracket classes like `[a-z]`
- heredocs via `<<DELIM`
- redirections: `>`, `>>`, `<`, `2>`, `2>>`, `2>&1`
- background jobs with `&`
- bash-like builtins documented in README

## Intentionally bounded / notable deviations
- subshell support is currently bounded to standalone groups, redirections on groups, and pipeline participation
- subshell-in-conditionals may still be deferred unless it falls out naturally from the bounded model
- command substitution remains bounded and not fully nested-parity complete
- heredocs are intentionally narrow:
  - no tab-stripping mode
  - no advanced heredoc expansion matrix beyond current behavior
- globbing leaves unmatched patterns literal
- parent-mutating builtins remain rejected in pipeline/background contexts, and mutate only subshell-local state inside `( ... )`
- history/completion UX remains rough/manual-primary

## Unsupported
- shell functions
- backtick command substitution
- brace expansion
- full general shell grammar parity
- full POSIX parity
