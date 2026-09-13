# Review rules: saving, reading and comparing deploy reports

Accepted findings about `lib/dash/report.rb`, `report/writer.rb`, `report/history.rb`, `report/trends.rb` and `lib/dash/cli/report.rb`. The subsystem itself is [../reports/summary.md](../reports/summary.md).

**The safe direction for everything here:** a report is a courtesy printed next to a deploy that already happened. Every failure in this path costs one yellow line, never a deploy — and a file it cannot read is skipped in silence, because the operator's reports directory is theirs.

*A rule with no **Proven by** line has no test that pins that specific behaviour — the gap is real, not an omission.*

### A report's name and its content arrive together, or neither does
- **Holds because:** every reader skips a file it cannot parse and `prune` only counts the files it could read, so a report left empty or half-written stays in the directory forever. `publish` writes a private `.<base>.<pid>.tmp` scratch file and then claims a name with `File.link` — atomic, and only if the name is free, so two runs racing for one second's name each keep their own file. `Errno::EEXIST` moves to the next `-N`.
- **Where:** `lib/dash/report/writer.rb#publish` (lines 47-58), `#linked`, `#claim`
- **Proven by:** `test/report/writer_test.rb:97` ("two runs that would share a name each keep their own file"), `:113` ("the file appears whole or not at all"), `:128` ("a name that is already taken is never written over"), `:149`, `:194`
- **Origin:** cubic learning 9cee329d; PR #158

### Without hard links the name is claimed with `O_EXCL` and the finished scratch is renamed onto it
- **Holds because:** a fallback that *replaces* is the bug moved to the filesystems least likely to be tested, and writing through the claiming descriptor trades an empty-file window for a half-written one. `placeholder?` creates with `WRONLY|CREAT|EXCL` (never replaces); `filled` renames the completed scratch on top. The placeholder is the one thing nothing else would clean up, so it comes down in an `ensure` **gated on the scratch file still existing** — the rename consumes the scratch, so the filesystem itself answers "did the publish happen". A boolean flag set after the rename has its own interrupt window, in which a published report would be deleted. `Interrupt` is not a `StandardError`, so a plain Ctrl-C reaches these `ensure`s too.
- **Where:** `lib/dash/report/writer.rb#created` (lines 76-82), `#placeholder?`, `#filled` (lines 95-101)
- **Proven by:** `test/report/writer_test.rb:162`, `:181`, `:204`, `:220` ("a report already published is never deleted by the cleanup"), `:236` ("an interrupt without hard links leaves no empty report either")
- **Origin:** cubic learning 9cee329d; PR #158

### A saved report is validated by rendering it, not field by field
- **Holds because:** a hand-edited file that parses but holds the wrong shapes crashes `dash report` somewhere far from the mistake, or — worse — renders as an empty table. Mirroring the whole schema in an assertion is a second copy that drifts. `well_formed?` checks the top-level fields the writer always sets by shape and then calls `Dash::Report.from_h(document).lines`; a raise there lands in `entry_for`'s rescue and the file is skipped with the unreadable ones. `runtime` (non-numeric) and `error` (non-hash) get their own type checks **because rendering never reads them** and the trend rules and `dash report`'s `error_note` do.
- **Where:** `lib/dash/report/history.rb#well_formed?` (lines 76-85), `#entry_for` (lines 59-68)
- **Proven by:** `test/report/history_test.rb:56`, `:72`, `:84` ("a document whose fields are the right shape but the wrong type is skipped too")
- **Origin:** cubic learning d3f6517b; PR #158

### A collision suffix orders numerically after the name it collided with
- **Holds because:** `-` sorts before `.`, so byte for byte `X-2.json` reads as *older* than `X.json` and with `history: 1` the prune deletes the run just written. `order_key` splits a trailing `-N` off and compares it as an integer, so `X.json` < `X-2.json` < `X-10.json`. The suffix is unambiguous because a report name ends in the command and no command is a number.
- **Where:** `lib/dash/report/history.rb#order_key` (lines 52-57)
- **Proven by:** `test/report/history_test.rb:100` ("a collision suffix orders after the name it collided with")
- **Origin:** cubic learning e5ec1cc7; PR #158

### A saved report's `status` describes the command frame that finalised it
- **Holds because:** `print_runtime` nests, and only depth zero finalises. In a plain `dash deploy` the `post-deploy` hook fires *outside* `print_runtime`, so a `HookError` there leaves the report `succeeded` — the image was built and the containers booted, and calling that run failed would make the report disagree with the servers. Under `dash setup` the same hook fires inside the outer frame, so it sets `@report_error` before the deferred report is written and that run is recorded `failed`.
- **Where:** `lib/dash/cli/base.rb#print_runtime` (lines 146-162), `#report_run` (lines 182-190); `lib/dash/cli/main.rb#deploy` (line 69)
- **Origin:** cubic learning 1a20463d; PR #158. Documented in `docs/app/views/docs/pages/deploy_report.rb`

### `dash report --last N` is one row per report, over a history scoped by destination and not by command
- **Holds because:** `History` narrows on `destination` only, so `setup`, `redeploy` and `rollback` runs all get a row — the operator asked what has been deployed here, not what `deploy` did. Only the trend rules narrow by command.
- **Where:** `lib/dash/cli/report.rb#show`; `lib/dash/report/history.rb#entry_for`
- **Proven by:** `test/cli/report_test.rb:47` ("--last prints one row per report, oldest first"), `:88` ("another destination's reports are not this one's history")
- **Origin:** cubic learning ab926741; PR #158

### `--last` rejects anything that is not a positive whole number, in a sentence
- **Holds because:** Thor's `:numeric` hands `-1` straight through and `Array#first(-1)` raises `ArgumentError: negative array size` — a backtrace where a sentence belonged.
- **Where:** `lib/dash/cli/report.rb#count?` (lines 34-36)
- **Proven by:** `test/cli/report_test.rb:59` ("--last with a number that is not a count says so instead of crashing")
- **Origin:** PR #158

### A trend is computed only over retained, same-command, succeeded reports
- **Holds because:** a failed deploy's phases are truncated wherever it died, so comparing against them invents a speed-up; and `boot` seconds from a `setup` are not comparable with a `redeploy`'s. `comparable` filters on `command` and `status == "succeeded"` and then takes the first `WINDOW = 5`; fewer than `MINIMUM_HISTORY = 3` of those and there is no trend. A destination whose last three deploys failed therefore has none.
- **Where:** `lib/dash/report/trends.rb#comparable` (lines 43-48)
- **Proven by:** `test/report/trends_test.rb:47` ("fewer than three comparable deploys is not a trend"), `:51` ("only the same command counts, and only the runs that succeeded"), `:59`
- **Origin:** cubic learning 3cc56aa7; PR #158

### A phase is matched by name **and** `depth == 0`
- **Holds because:** the per-host rows inside `Boot` are named after the host, and nothing stops an operator naming a role `Boot`. Matching on name alone would compare a role's row with the phase that wraps it.
- **Where:** `lib/dash/report/trends.rb#phase_seconds` (lines 106-112); `lib/dash/timings.rb#seconds_for` (lines 137-139)
- **Proven by:** `test/report/trends_test.rb:66` ("a phase this run never had is not compared against one it did")
- **Origin:** PR #158

### A context transfer with a size and no duration prints `n/a`, never `0.0s`
- **Holds because:** `context_bytes` comes from the `transferring context:` line and the seconds from that line's own timing or the vertex `DONE`. A build killed in between has one and not the other, and `0.0s` is a measurement nobody took.
- **Where:** `lib/dash/report.rb#context_row` (lines 147-149); `lib/dash/dockerfile/rules/context_size.rb#elapsed`
- **Proven by:** `test/report_test.rb:66` ("a context transfer with no DONE reports its size and no fabricated duration")
- **Origin:** cubic learning 4ba85c81; PR #156

### Failed build steps dedupe on `[label, error]`, both halves
- **Holds because:** a multi-platform build fails the same step once per platform with the same message, and that is one row. Two *different* steps that happen to share a message are two rows, and so are two different errors on one step — deduping on either half alone loses a real failure.
- **Where:** `lib/dash/report.rb#build_lines` (lines 113-125)
- **Proven by:** `test/report_test.rb:74` ("the same failure on every platform of a multi-platform build prints one row"), `:84` ("different steps failing with the same message each get a row"), `:93` ("different failures on the same step still each get a row")
- **Origin:** cubic learning e519c2d2; PR #156

### `analyze!` resets `@advice` before either early return
- **Holds because:** a second `analyze!` that turns out to have nothing to say — advice switched off, or no Dockerfile — would otherwise leave the previous run's findings standing and print them under a deploy they have nothing to do with.
- **Where:** `lib/dash/report.rb#analyze!` (lines 86-103)
- **Proven by:** `test/report_test.rb:183` ("analyze! clears earlier advice when it has nothing to say")
- **Origin:** PR #157

### Restored entries come back parentless
- **Holds because:** `#to_h` writes the subtree totals it computed at render time. Re-nesting the entries on the way back in would roll those totals up a second time, and a saved report would print bigger numbers than the deploy did.
- **Where:** `lib/dash/report.rb#from_h` (lines 39-48); `lib/dash/timings.from_h` (lines 39-41)
- **Proven by:** `test/report_test.rb:232` ("from_h re-renders a saved report line for line"), `:244`
- **Origin:** PR #158
