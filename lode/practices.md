# Practices

Patterns this repository holds itself to that `../.claude/rules/` does not already state. The rules cover layering, Minitest-not-RSpec, conventional commits, release ordering and the `MINIMUM_VERSION` interpolation; read those first ([coding-style](../.claude/rules/coding-style.md), [testing](../.claude/rules/testing.md), [git-workflow](../.claude/rules/git-workflow.md)). What follows is the rest, learned from review.

## Say the safe failure direction out loud

Every approximating component in dash names the direction it is allowed to be wrong in, in a comment at the top of the file, before the first method. `Dash::Dockerfile::Parser` (lines 7-9): a file it cannot make sense of must produce *fewer* findings, never an exception. `Dash::Dockerfile::Dockerignore` (lines 3-5): negations are skipped rather than applied, so a path it says is covered might still ship — it costs advice, never a false accusation. `Dash::Report::History`: a file it cannot read is skipped in silence, because the alternative is a warning on a deploy about somebody else's half-written file.

A reviewer's first question about a regex or a scanner is "what happens when this is wrong?", and a component that has not answered it in writing gets the answer wrong under pressure.

## A hand-written scanner gets a grammar table

`lib/dash/dockerfile/` approximates a grammar BuildKit owns. The forms it handles and the forms it deliberately gets wrong are enumerated in [dockerfile-advice/summary.md](dockerfile-advice/summary.md), one row per form, each with a test citation or an honest "no dedicated test". When a new form is added, the row comes with it; when a row has no test, that is a finding, not a footnote.

## Fail closed on an unreadable answer, not on a negated check

`! docker container inspect name >/dev/null 2>&1` cannot tell "no such container" from "the daemon could not be asked". A listing can: it exits 0 whichever way the match went and non-zero only on a genuine failure. `Dash::Commands::Base#confirmed_empty?` (lines 51-53) is the one shape absence is ever concluded from, and its argument must be a listing. The general form: when a command's exit status conflates "no" with "could not tell", find a command that does not.

## The name and the content of a written file arrive together

`Dash::Report::Writer#publish` (lines 47-58) writes to a private, pid-suffixed scratch file and then claims a name with `File.link` — atomic, and only if the name is free. There is never a moment where a report exists empty or half-written, because every reader skips what it cannot parse and the prune only counts what it could read, so anything left behind would stay forever. The no-hard-link fallback (`created`, lines 76-82) claims with `O_EXCL` and renames the finished scratch onto the placeholder; its cleanup asks the filesystem what happened (`File.exist?(scratch)`) rather than trusting a flag set after the fact, because a flag has its own interrupt window. `Interrupt` is not a `StandardError`, so every cleanup that must survive Ctrl-C lives in an `ensure`.

## Operator strings reach a shell only through the vocabulary

`Dash::Commands::Base#shell` single-quotes its payload and escapes embedded apostrophes; `Dash::Utils.argumentize` / `.optionize` build flag arrays. A `--resolver` name, a destination, a zone — all of them are operator input, and the nested `sh -c` in `Dash::Commands::Proxy::CertTransfer` is exactly where an apostrophe would otherwise end the quoting. A builder that hand-assembles a quoted string is the defect, whether or not today's inputs happen to be safe.

## Measure what the process already prints

`Dash::Build::ProgressParser` is an SSHKit interaction handler on the buildx stream dash was already printing: no second process, no `docker buildx history`, no extra round trip. The same instinct governs `lib/dash/sshkit_with_ext.rb`, which times the connects and commands SSHKit was making anyway. A measurement that costs a deploy a round trip is a measurement that gets turned off.

## The report may not fail the deploy — except at config time

Everything in the measure/analyse/save/ship chain is inside `Dash::Cli::Base#guarded_report` (lines 248-254) or its own rescue, and the visible cost of a failure is one yellow line. The single deliberate exception is `Dash::Configuration::Report`, which raises on an unrecognised `hadolint:` or a negative `history:` — those are typos that would otherwise read as "off", and an operator who loses findings silently never learns why.

## An assertion that cannot fail is worse than a missing one

Three separate review findings in this repo were tests that passed for the wrong reason: a round-trip count taken on `execute_command` while the code under test used `capture_with_info`; `2N+1 / N == 2` rounding a per-host drift away; a `stubs` where an `expects` was meant, on a path the fixture never reached. Before pinning a count or a call, prove the test fails without the change — revert the implementation and watch it go red. `test/cli/cli_test_case.rb` exists because that proof kept needing the same helpers.

## One fact, one place, across code and docs

A limit, a default, a status list or a phase name that appears in the code, in `lib/dash/configuration/docs/*.yml`, in a `docs/app/views/docs/pages/*` page and in an assertion must say the same thing in all four. `Dash::Report::Trends::OVERHEAD_PHASES` names four phase strings that `Dash::Cli::Main` and `Dash::Cli::Base` record, and `test/cli/main_test.rb:42` pins the table a real deploy prints — so renaming one of the three it covers cannot quietly turn a trend rule off. (`Acquire server lock`, the fourth, is not in that assertion: see [reports/summary.md](reports/summary.md).) When a change moves a fact, grep for its subject before finishing.

## Related

- [summary.md](summary.md) · [terminology.md](terminology.md) · [lode-map.md](lode-map.md)
- [review/](review/) — the accepted findings these practices came from
