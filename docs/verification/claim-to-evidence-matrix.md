# Claim-to-Evidence Matrix

This matrix is the primary ownership map for retained zig-shell claims after the focused subshells + stronger command substitution milestone.

| Claim | Primary evidence source | Supporting evidence | Status |
|---|---|---|---|
| Startup prompt appears | `zig build pty-smoke` | manual checklist, transcript | retained |
| Ctrl-C interrupts foreground child and returns prompt | `zig build pty-smoke` | transcript | retained |
| Background job launch returns prompt and `jobs` reports it | `zig build pty-smoke` | manual checklist, transcript | retained |
| `jobs %n` can report a single job | `zig build pty-smoke` | transcript | retained |
| Multi-job background state is observable | `zig build pty-smoke` | transcript | retained |
| Reap-before-next-prompt and job ID recycling work for background jobs | `zig build pty-smoke` | transcript | retained |
| Startup config affects current shell on startup | integration test (`src/test_support/harness.zig`) | transcript/manual demo | retained |
| History persists across restarts | integration test (`src/test_support/harness.zig`) | transcript/manual demo | retained |
| `history N` limits builtin output only | integration test (`src/test_support/harness.zig`) | manual checklist | retained |
| Append-on-exit writes only session-created history entries when `HISTAPPEND=1` | integration test (`src/test_support/harness.zig`) | transcript/manual demo | retained |
| History up/down navigation works interactively | manual checklist | transcript | retained, manual-primary |
| Command completion works for the bounded current subset | `zig build pty-smoke` | transcript, manual checklist | retained, bounded subset |
| Path completion works for the bounded current subset | `zig build pty-smoke` | transcript, manual checklist | retained, bounded subset |
| `type` reports builtin vs executable vs not found consistently with execution lookup | integration test (`src/test_support/harness.zig`) | transcript/manual demo | retained |
| `2>>` appends stderr correctly | integration test (`src/test_support/harness.zig`) | transcript/manual demo | retained |
| Child-safe builtins can participate in pipelines while parent-only builtins remain rejected | integration test (`src/test_support/harness.zig`) | manual checklist | retained |
| `&&` / `||` short-circuit correctly | integration test (`src/test_support/harness.zig`) | docs | retained |
| Unquoted globbing expands and quoted globs stay literal | integration test (`src/test_support/harness.zig`) | docs | retained |
| Heredoc content reaches stdin of the target command | integration test (`src/test_support/harness.zig`) | docs | retained |
| Bounded `$(...)` command substitution works in basic argument position | integration test (`src/test_support/harness.zig`) | docs | retained |
| Bounded subshell groups `( ... )` execute and isolate parent state correctly | integration test (`src/test_support/harness.zig`) | docs | retained |
| Prompt can be influenced by shell config (`PS1`) | manual checklist | transcript | retained, manual-primary |
| Cursor-aware editing is available (left/right, insertion, backspace at cursor) | manual checklist | transcript | retained, manual-primary |
| Completion redraw/candidate UX polish | manual checklist only | transcript | manual-only |
| `docs/verification/interactive-transcript.txt` | supplemental only | generated script output | non-canonical |
