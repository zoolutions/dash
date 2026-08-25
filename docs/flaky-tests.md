# Flaky tests

One entry per investigated intermittent failure. Prune entries whose tests no longer exist.

---

## 2026-07-29 — `bin/test` exits 1 after reporting 0 failures

**Signature class:** CI-environment / process-exit divergence — *unresolved, watch-listed*

**Evidence:** [run 30448314008, job 90564015915](https://github.com/mhenrixon/kamal/actions/runs/30448314008/job/90564015915)
(`issue-46-boot-limit-denominator`, commit `63402726`, Ruby 3.4 × `gemfiles/rails_edge.gemfile`).

The `Run tests` step printed:

```
Finished in 551.877460s, 2.1019 runs/s, 7.1447 assertions/s.
1160 runs, 3943 assertions, 0 failures, 0 errors, 0 skips
```

and then produced **no further output**, yet the step annotation was
`Process completed with exit code 1`. The next step's group header is timestamped 20ms
later, so nothing was truncated — the process exited nonzero silently, after minitest had
already reported everything green.

**Matrix:** 1 of 7 test cells. The other `rails_edge` cells (3.3, 4.0) and every default-Gemfile
cell passed, so this is not a Ruby- or Rails-version break.

**Root cause:** not established. Ruled out so far:

- **A test-logic failure** — minitest reported 0 failures / 0 errors / 0 skips, and all 18
  integration tests ran (0 skips means the `build_circuit` never tripped).
- **`Dash::Commander`'s `at_exit { @output_logger&.close }`** (`lib/dash/commander.rb`) —
  the only `at_exit` in the codebase. It is registered from `configure_output_with`, which
  returns early unless `config.output.enabled?`, i.e. unless the config carries an `output:`
  key. No fixture and no test sets one, so it never registers during the suite.
- **A deterministic regression** — re-running the identical commit
  (`gh run rerun 30448314008 --failed`) turned every job green.

**Reproduction:** none found. Not reproducible locally: the failure requires the integration
suite, which needs Docker, and the unit-only suite cannot exhibit it. The Actions API serves
the same log blob for both `Tests (Ruby 3.4)` job IDs (identical seed and timestamps), so the
passing and failing cells of that run cannot be diffed.

**Detection recipe** — if it recurs, this is the fingerprint to match:

```bash
gh run view <RUN_ID> --job <JOB_ID> --log | grep -E "runs, .* assertions|Process completed"
# flake iff: "0 failures, 0 errors" AND the step still failed
```

Next steps if it recurs: capture `echo $?` around `bin/test` in the workflow, and print
`Minitest.after_run` registrations plus any live threads at exit, to distinguish a raising
at-exit hook from a signal.

**Do not** paper over this with a retry on the `Run tests` step — a silent nonzero exit from a
suite that reported success is exactly the failure mode a retry would hide permanently.
