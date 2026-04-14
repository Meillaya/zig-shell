# Next Major Milestones

These are the most natural follow-on milestones after the bounded-functions release.

## 1. Richer function semantics
- recursion policy refinement
- additional positional parameter behavior (`$#`, `$@` if desired)
- clearer function/body edge-case behavior
- decide whether to add bounded local variables

## 2. Deeper command language
- nested command substitution beyond the current bounded model
- subshells in more compound-command positions
- broader compound-command ownership in parser/IR
- optional brace expansion
- optional backtick substitution if compatibility is worth it

## 3. Better interactive UX
- history search
- richer completion display
- less redraw flicker
- better cursor/editing ergonomics
- more configurable prompt behavior

## 4. Stronger correctness and compatibility
- broaden the compatibility matrix
- tighten expansion-order semantics further
- more edge-case regression tests for functions/subshells/substitution/globbing/heredocs
- clearer bash-like vs intentionally unsupported boundaries

## 5. Distribution and adoption
- more release assets
- install helper script
- package-manager integration later if wanted
- changelog / release notes discipline

## Recommended next milestone
If continuing immediately, the best next milestone is:

**Richer function semantics + deeper nested command substitution**

Why:
- builds directly on the bounded function/runtime model just landed
- improves scripting value the most
- reduces the biggest remaining semantic limitations before large UX work
