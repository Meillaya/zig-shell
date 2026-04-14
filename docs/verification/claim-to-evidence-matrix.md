# Claim-to-Evidence Matrix

This matrix is the primary ownership map for retained Zig Shell v1 claims during stabilization milestone 1.

| Claim | Primary evidence source | Supporting evidence | Status |
|---|---|---|---|
| Startup prompt appears | `zig build pty-smoke` | manual checklist, transcript | retained |
| Ctrl-C interrupts foreground child and returns prompt | `zig build pty-smoke` | transcript | retained |
| Background job launch returns prompt and `jobs` reports it | `zig build pty-smoke` | manual checklist, transcript | retained |
| Startup config affects current shell on startup | integration test (`src/test_support/harness.zig`) | transcript/manual demo | retained |
| History persists across restarts | integration test (`src/test_support/harness.zig`) | transcript/manual demo | retained |
| History up/down navigation works interactively | manual checklist | transcript | retained, manual-primary |
| Command completion works for the bounded current subset | `zig build pty-smoke` | transcript, manual checklist | retained, bounded subset |
| Path completion works for the bounded current subset | `zig build pty-smoke` | transcript, manual checklist | retained, bounded subset |
| Completion redraw/candidate UX polish | manual checklist only | transcript | manual-only |
| `docs/verification/interactive-transcript.txt` | supplemental only | generated script output | non-canonical |
