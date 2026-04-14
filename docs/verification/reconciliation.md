# Stabilization Reconciliation — Zig Shell V1 Claims

## Controlled Repro Summary
Fresh repro against `zig-out/bin/zig-shell` in a controlled HOME-scoped PTY environment found:
- prompt appears: **works**
- rc/config loading: **works** (`echo $ZIGSHRC_LOADED` produced `1`)
- history persistence: **works** (`.zigsh_history` persisted commands)
- history recall via Up-arrow: **under-proven by current harness**, because the last recorded command was `exit`, so recall targeted the wrong history item
- background jobs / `jobs`: **works** (`jobs` showed `Running`)
- Ctrl-C / foreground recovery: **works**
- command completion: **works as bounded candidate listing/common-prefix behavior**
- path completion: **works**

## Classification
| Claim | Classification | Notes | Action |
|---|---|---|---|
| rc/config loading | harness/evidence bug | stale transcript/check logic marked false despite visible proof | replace weak proof with deterministic integration + refreshed transcript policy |
| history persistence | claim retained | file-backed behavior already works | add explicit integration proof |
| history recall | harness/evidence bug / UX-manual boundary | current repro recalled `exit` because harness targeted the wrong last item | move arrow recall to manual-primary or improve controlled recall flow |
| command completion | harness/evidence bug | current stale transcript/checking was too brittle | strengthen PTY/manual evidence and narrow wording to bounded subset |
| path completion | harness/evidence bug | current repro shows working bounded path completion | strengthen PTY/manual evidence |
| background jobs / `jobs` | harness/evidence bug | stale transcript flagged false despite visible `Running` output | refresh PTY proof and demote old transcript |
| Ctrl-C / foreground recovery | retained claim | already backed by PTY smoke | keep protected |

## Go / No-Go for Code Changes
- **No broad runtime feature work justified** by current repro.
- Prefer **verification-path changes first**:
  - integration tests for startup config + history persistence
  - stronger PTY smoke coverage for rc/jobs/completion as stable as possible
  - manual-primary checklist for redraw-sensitive history-navigation UX
  - transcript demotion or controlled regeneration
- Only perform behavior fixes if a claim fails again under controlled proof.

## Transcript Policy
`docs/verification/interactive-transcript.txt` should no longer be treated as canonical evidence. It must either:
1. be regenerated from a controlled verification flow, or
2. be explicitly supplemental/manual evidence.
