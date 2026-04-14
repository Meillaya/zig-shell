# Interactive Verification Checklist

This checklist covers **manual-primary UX checks** that are intentionally separate from the canonical automated proof sources.

## Manual-primary checks
- Use Up/Down arrows to navigate history entries and confirm the line buffer updates as expected.
- Confirm completion redraw/candidate-list behavior is understandable enough for the current bounded v1 shell.
- Confirm prompt stability through repeated command/job cycles.

## Canonical automated checks (run separately)
- `zig build`
- `zig build test`
- `zig build pty-smoke`

## Evidence ownership note
- `docs/verification/interactive-transcript.txt` is supporting evidence only.
- Canonical proof ownership lives in `docs/verification/claim-to-evidence-matrix.md`.
