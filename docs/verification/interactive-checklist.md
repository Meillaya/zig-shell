# Interactive Verification Checklist

This checklist covers **manual-primary UX checks** that are intentionally separate from the canonical automated proof sources.

## Manual-primary checks
- Use Up/Down arrows to navigate history entries and confirm the line buffer updates as expected.
- Use Left/Right arrows to move inside the current line and confirm insertion/backspace occur at the cursor position.
- Confirm completion redraw/candidate-list behavior is understandable enough for the current bounded shell.
- Confirm `PS1` from startup config changes the prompt as expected.
- Confirm prompt stability through repeated command/job cycles.

## Canonical automated checks (run separately)
- `zig build`
- `zig build test`
- `zig build pty-smoke`
- `python3 scripts/generate_interactive_transcript.py zig-out/bin/zig-shell`

## Evidence ownership note
- `docs/verification/interactive-transcript.txt` is supporting evidence only.
- Canonical proof ownership lives in `docs/verification/claim-to-evidence-matrix.md`.
