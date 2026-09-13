# Review rules: the advice rules and hadolint

Accepted findings about `lib/dash/dockerfile/rules/*` and `hadolint.rb`. The rule inventory, severities and thresholds are in [../dockerfile-advice/summary.md](../dockerfile-advice/summary.md); the parser's own rules are in [dockerfile-parsing.md](dockerfile-parsing.md).

A rule id is a public string: an operator writes it in `report: ignore:`, and it is derived from the class name (`name.demodulize.underscore.dasherize`). **Renaming a rule class is a breaking change to somebody's `deploy.yml`.**

*A rule with no **Proven by** line has no test that pins that specific behaviour — the gap is real, not an omission.*

### `latest-base` never flags `FROM scratch`
- **Holds because:** `scratch` is Docker's reserved empty base. There is no tag to pin and no image to resolve, so the advice has no action behind it.
- **Where:** `lib/dash/dockerfile/rules/latest_base.rb#finding_for`, `lib/dash/dockerfile/stage.rb::SCRATCH`
- **Proven by:** `test/dockerfile/analyzer_test.rb:184` ("latest-base skips scratch and warns on an explicit :latest behind an interpolated registry")
- **Origin:** cubic learning 0e1c3074; PR #157

### `root-user` says the container runs as whatever the base image left it as, never "always root"
- **Holds because:** a final stage with no `USER` inherits the base image's user, which for nearly every official image is root — but not for all of them, and an operator on a rootless base reading "runs as root" learns that dash's advice is wrong about their file. The message says "so the container runs as whatever the base image does — usually root".
- **Where:** `lib/dash/dockerfile/rules/root_user.rb`
- **Proven by:** `test/dockerfile/analyzer_test.rb:70` ("root-user looks at the shipped final stage only")
- **Origin:** cubic learning 40ce2266; PR #157

### `secret-in-build-arg` reads the legacy `ENV KEY value` form as declaring exactly one name
- **Holds because:** `ENV API_TOKEN some value` declares `API_TOKEN`, whatever the value holds, while `ENV A=1 B=2` declares two. `names` branches on whether the first whitespace-delimited word contains `=`.
- **Where:** `lib/dash/dockerfile/rules/secret_in_build_arg.rb#names`
- **Safe direction:** a `NAME=` token inside a quoted value is read as a declaration. That was reviewed and kept: the cost is one extra warning, not a missed one.
- **Proven by:** `test/dockerfile/analyzer_test.rb:236` ("secret-in-build-arg reads the legacy ENV form")
- **Origin:** PR #157

### `cache-busting-arg` needs the whole ARG name and ignores a reference from `FROM`
- **Holds because:** `$SHA_LONG` is not a reference to `SHA`, so the pattern requires `}` or a non-word character after the name. And an ARG a `FROM` uses is pinning the base image with it — a different thing entirely, which "reference it after the dependency install" could never fix — so `FROM` instructions are skipped when looking for the reference.
- **Where:** `lib/dash/dockerfile/rules/cache_busting_arg.rb#reference_before`
- **Proven by:** `test/dockerfile/analyzer_test.rb:228` ("cache-busting-arg needs the whole name, not a prefix, and ignores FROM")
- **Origin:** cubic learning 0e88521a; PR #157

### `single-stage-build-deps` ends its package pattern with a lookahead, not `\b`
- **Holds because:** `+` is not a word character, so `g\+\+\b` never matches `g++`. `(?=[\s;&|)]|$)` accepts whitespace, a shell separator or end of string.
- **Where:** `lib/dash/dockerfile/rules/single_stage_build_deps.rb::BUILD_PACKAGES`
- **Proven by:** `test/dockerfile/analyzer_test.rb:191` ("single-stage-build-deps recognises g++"), `:287` ("sees a package followed by a shell separator")
- **Origin:** cubic learning 464289fd; PR #157

### `curl-pipe-shell` sees `sudo` with flags, flags that take an argument, and process substitution
- **Holds because:** `curl … | sudo -u root bash` and `bash <(curl …)` run unverified code exactly as `curl … | sh` does. `SHELL` allows a `sudo` prefix with repeated `-flag [value]` pairs; `PIPE_TO_SHELL` matches both the pipe and the `<(…)` form.
- **Where:** `lib/dash/dockerfile/rules/curl_pipe_shell.rb::SHELL`, `::PIPE_TO_SHELL`
- **Proven by:** `test/dockerfile/analyzer_test.rb:268` ("curl-pipe-shell sees sudo flags and process substitution"), `:291` ("sees sudo options with arguments")
- **Origin:** cubic learning bbe501be; PR #157

### `inline-env-blob` counts quoted and escaped values, and claims nothing about ARGs
- **Holds because:** `FOO="a b" BAR='c d' BAZ=e\ f cmd` is three assignments, and an `ASSIGNMENT` pattern that stops at the first space counts one. The suggestion names an env file at runtime or one `ENV` block for the build-time values — moving them to ARGs would not preserve the cache, and the earlier wording implied it would.
- **Where:** `lib/dash/dockerfile/rules/inline_env_blob.rb::ASSIGNMENT`, `::SUGGESTION`
- **Proven by:** `test/dockerfile/analyzer_test.rb:262` ("inline-env-blob counts assignments with quoted values")
- **Origin:** cubic learnings 03fda83b, 028e1e0c; PR #157

### A `--mount=type=cache` suggestion names the package manager's real cache directory
- **Holds because:** the target is pasted straight into the operator's Dockerfile. Bundler's is `/usr/local/bundle/cache`, Go's is `/go/pkg/mod` — a plausible-looking wrong path produces a cache mount that caches nothing and looks like it works. Each of the twelve `DEPENDENCY_INSTALLS` entries carries its own target, and apt's is `/var/cache/apt`.
- **Where:** `lib/dash/dockerfile/context.rb::DEPENDENCY_INSTALLS` (lines 11-24), `::APT_INSTALL`; `lib/dash/dockerfile/rules/no_cache_mount.rb#target_for`
- **Origin:** cubic learning 16aff50f; PR #157

### `no-cache-mount` reads every `--mount` flag on an instruction, not just the first
- **Holds because:** a `RUN` may carry several mounts and only one of them is the cache. `Instruction#flag` deliberately returns the first value for callers that only care whether a flag is present; this rule asks for `Array(flags["mount"])` instead.
- **Where:** `lib/dash/dockerfile/rules/no_cache_mount.rb#findings`; `lib/dash/dockerfile/instruction.rb#flag`
- **Proven by:** `test/dockerfile/parser_test.rb:59` ("repeated flags are all kept")
- **Origin:** PR #157

### `cache-export-cost` matches `mode=max` as a whole comma-separated option
- **Holds because:** `cache_to` is an option list. A substring match fires on `mode=maximal` or on a path that happens to contain the text; splitting on commas and comparing exactly does not.
- **Where:** `lib/dash/dockerfile/rules/cache_export_cost.rb#mode_max?`
- **Proven by:** `test/dockerfile/analyzer_test.rb:242` ("cache-export-cost reads the mode option exactly")
- **Origin:** PR #157

### `apt-hygiene` checks each install segment on its own, and a cleanup only counts after the *last* apt operation
- **Holds because:** one `RUN` may hold several `apt-get install` calls, and a later compliant one must not vouch for an earlier one that omitted `--no-install-recommends`. A cleanup placed before a second `apt-get update` has been undone by the time the layer is written. `problems_in` selects every install segment and finds the cleanup with `segments.drop(last_apt + 1)`.
- **Where:** `lib/dash/dockerfile/rules/apt_hygiene.rb#problems_in`, `::SEGMENT` (which splits on `&&`, `||`, `;` and `\n`, so a heredoc body's lines are segments too)
- **Proven by:** `test/dockerfile/analyzer_test.rb:204` ("apt-hygiene checks every install in a RUN and the order of the cleanup"), `:281` ("reads each line of a heredoc RUN as its own command")
- **Origin:** cubic learning c041c19f; PR #157

### The measured rules stay silent without a build report; the rest quote numbers only when there are numbers
- **Holds because:** `dash doctor` and a `--skip-push` deploy have no build to measure, and advice that names a duration nobody measured is worse than advice that names none. `context-size`, `cache-export-cost` and `uncached-install` return `[]` without `build`; `copy-before-install` appends `(measured N.Ns uncached)` only when the matching step exists, is not cached and is not zero.
- **Where:** `rules/context_size.rb`, `rules/cache_export_cost.rb`, `rules/uncached_install.rb`, `rules/copy_before_install.rb#measured`
- **Proven by:** `test/dockerfile/analyzer_test.rb:34` ("copy-before-install appends the measured cost when the build measured that step"), `:41` ("a cached install step adds no measured note"), `:143`, `:152`, `:158`, `:170`
- **Origin:** cubic learning b1721a6f; PR #157

### `Rules::Base` requires `active_support/core_ext/string/inflections` itself
- **Holds because:** `#underscore` and `#dasherize` derive every rule id, and this gem cannot assume a host application loaded ActiveSupport's string extensions. Without the require the whole rule set raises `NoMethodError` on first use.
- **Where:** `lib/dash/dockerfile/rules/base.rb` (line 2)
- **Origin:** cubic learning f4047c2a; PR #157

### hadolint distinguishes four outcomes, and blank output is not one of the failures
- **Holds because:** an operator seeing "hadolint could not run" for a file hadolint was perfectly happy with learns to ignore the line. Blank stdout and an empty JSON array are both "no findings" and return `[]`. Only `JSON::ParserError`, or valid JSON that is not an array, becomes `hadolint output could not be parsed`; a non-zero exit or any other exception becomes `hadolint could not run`. Only hadolint's `error` level maps to `:warn` — a style note must not compete with a measured finding.
- **Where:** `lib/dash/dockerfile/hadolint.rb#findings` (lines 34-51), `::SEVERITIES`
- **Proven by:** `test/dockerfile/hadolint_test.rb:25`, `:32`, `:38`, `:53`
- **Origin:** cubic learning 2e87df3e; PR #157

### The analyzer is given the resolved on-disk path *and* the path findings print
- **Holds because:** a deploy analyses its git clone while the operator's `builder: dockerfile:` names a path in their repo. Passing one string for both either opens the wrong file or prints a path the operator cannot find. `Analyzer#initialize` takes `path:` (what prints) and `file:` (what opens), defaulting `file` to `path`; hadolint gets both.
- **Where:** `lib/dash/dockerfile/analyzer.rb#initialize`, `.for_file`; `lib/dash/dockerfile/hadolint.rb#initialize`
- **Proven by:** `test/dockerfile/hadolint_test.rb:44` ("the resolved file is what runs, the display path is what prints")
- **Origin:** cubic learning 75405478; PR #157

### `dash build dev` analyses the working directory it built, not a clone it never made
- **Holds because:** `dev` builds from `.`; pointing the analysis at the clone path a `push` would have used reads a Dockerfile that has nothing to do with the image just produced.
- **Where:** `lib/dash/cli/build.rb#dev` passes `build_directory: "."` to `record_build_report`
- **Proven by:** `test/cli/build_test.rb:169` ("dev analyses the working directory, not the clone directory"); `test/report_test.rb:190` covers the `build_directory:` keyword itself
- **Origin:** cubic learning aa116516; PR #157

### Not a bug: a `#` comment inside a single-line `RUN` is not treated as an apt operation
- **Holds because:** BuildKit does not keep comments inside a command either — comment lines between continuations are dropped before the shell ever sees them, and this parser drops them the same way. Teaching apt-hygiene to recognise `#` inside one line would diverge from the file BuildKit actually builds.
- **Where:** `lib/dash/dockerfile/parser.rb#join_continuations` (line 90); `lib/dash/dockerfile/rules/apt_hygiene.rb`
- **Origin:** cubic learning 94f04612; PR #157 (suggestion declined)

### Not a bug: a bare `ARG GITHUB_TOKEN` with no default is still flagged
- **Holds because:** the *value* passed with `--build-arg` is recorded in the history of every layer that consumes it — `docker history` shows it — so "no default in the Dockerfile" is not "no secret in the image". The rule is about the name declaring a secret channel, not about a literal in the file.
- **Where:** `lib/dash/dockerfile/rules/secret_in_build_arg.rb`
- **Proven by:** `test/dockerfile/analyzer_test.rb:81` ("secret-in-build-arg lets the dummy key through") pins the one allowed name, `SECRET_KEY_BASE_DUMMY`
- **Origin:** cubic learning 1731a953; PR #157 (suggestion declined)
