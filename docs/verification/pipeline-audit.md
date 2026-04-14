# Pipeline Builtin Audit

This audit closes the missing-items pipeline question with a bounded policy rather than open-ended redesign.

## Child-safe builtins
These are allowed to run in pipeline child contexts:
- `echo`
- `pwd`
- `history`
- `type`

## Parent-only builtins
These remain intentionally rejected in pipeline/background contexts because they mutate parent shell state or require the interactive parent shell:
- `cd`
- `exit`
- `export`
- `unset`
- `source` / `.`
- `jobs`
- `fg`
- `bg`

## Closure decision
- The only concrete missing child-safe builtin gap was `type`, which is now implemented for standalone and pipeline child contexts.
- Parent-only rejection remains the correct policy and is preserved intentionally.
