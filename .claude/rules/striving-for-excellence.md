# Striving for Excellence

The principle: when you find something wrong while doing something else, fix it. The hard part is judgment — when does "fixing it" expand scope inappropriately, and when does it codify the right shape for the next person?

This document is the operational guide.

## What "in the path" means

The principle applies to wrongness *in the path* of the work you're already doing. Not wrongness in a file you'd have to detour to find.

In path:
- You're adding a flag to a `Dash::Commands::*` builder and notice the sibling method hand-rolls the same docker arguments a shared helper already produces.
- You're adding a new caller of a config accessor and its API forces every caller to re-implement the same nil-handling.
- You're fixing a bug and realize the surrounding code has a related bug the tests didn't catch.

Out of path:
- You're fixing a CLI command and decide to also refactor a configuration validator you noticed last week.
- You're adding a feature and decide to restructure `test/fixtures/` while you're there.
- You're fixing a typo and decide to rewrite the layer below it.

The test: did the work itself surface the wrongness, or did you go looking for it? If the wrongness was already on screen, it's in path.

## Don't add new callers of code you know is wrong

The most operational form of the principle. If your change would add a caller to a method you've just diagnosed as wrong — a command builder that ignores config the operator set, a version comparison that mishandles fork tags — stop. The choice is:

- A. Add the caller, ship the ticket, defer the fix to a follow-up.
- B. Fix the underlying thing first, then add the caller using the right shape.

A is easier. B is usually right when the fix is in path — you've already been reading and reasoning about the wrong code, and the alternative is another caller of a thing you know is wrong plus a follow-up PR that touches the same files again. This matters double in a fork: every caller of a wrong shape is another conflict surface for the next upstream sync.

If you'd be the third caller of a workaround, stop. Either fix the underlying thing or escalate the question.

## Refactor-depth rule

When a test failure or rubocop offense flags one wrong spot in a file, look for sibling wrong shapes — even ones no tool flags. The tool is a heuristic; the goal is the right shape, not "the check passes."

The half-measure: fix only the flagged line, ship, keep the diff small. The right thing: if fixing the flagged line introduces a new pattern into the file (a shared helper, `MINIMUM_VERSION` interpolation instead of a hardcoded tag), migrate the file's siblings of the old pattern too. A file that mixes two shapes teaches the next reader whichever one they hit first.

This applies when the work surfaces sibling wrongness in the same file. It doesn't apply to wrongness in a different file you'd have to seek out.

## What this is NOT

Not "expand scope to fix unrelated things." If your task is "fix the healthcheck port bug" and the surrounding code has nothing structurally wrong, ship the bug fix. Don't rewrite the command builder.

Not "spend a week on the perfect abstraction when a small fix is correct." Excellence is doing the right thing within the work, not creating new work. If the small fix IS the right shape, the small fix is excellence.

Not license to break staged-migration boundaries. If the wrongness lives in code frozen for compatibility (rare since the 2026-08 clean break — e.g. on-server artifact names awaiting the staged rename bridge, see `CLAUDE.md`), make it a deliberate, documented change. Escalate to the user.

The litmus test: would a reviewer reading the PR feel the diff tells a coherent story, or that you've bundled unrelated cleanup? If the helper fix makes the feature commits cleaner, it's part of the same story. If you're "while I'm here" cleaning up something disconnected, it's separate work.

When in doubt: ask the user. The answer is almost always "do it right" if the right thing is in path.
