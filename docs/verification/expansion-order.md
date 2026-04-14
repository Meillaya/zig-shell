# Expansion Order

This document defines the bounded expansion order for the current subshells + command substitution milestone.

## Order
1. **Variable expansion** (`$VAR`, `${VAR}`)
2. **Command substitution** (`$(...)`)
3. **Globbing** (`*`, `?`, `[a-z]`) on unquoted words only
4. **Redirection target expansion** using the same bounded rules as command words

## Quoting rules
- **Single-quoted** text is literal.
- **Double-quoted** text allows variable expansion and command substitution, but does **not** allow globbing.
- **Unquoted** text allows variable expansion, command substitution, and globbing.

## Word splitting
- General shell-style word splitting remains intentionally **absent/bounded**.
- Expansion produces a single word unless globbing expands it into multiple path matches.

## Notes
- Unmatched globs remain literal.
- Supported command substitution is bounded and internal to this shell’s own parser/executor path.
- More complex POSIX-compatible expansion ordering remains future work.
