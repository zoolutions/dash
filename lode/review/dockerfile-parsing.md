# Review rules: the Dockerfile parser and the build-step matcher

Accepted findings about `lib/dash/dockerfile/parser.rb`, `stage.rb`, `instruction.rb`, `document.rb`, `dockerignore.rb` and `Context`'s matching helpers. The grammar table these describe from the outside is in [../dockerfile-advice/summary.md](../dockerfile-advice/summary.md).

**The safe direction for everything in this file:** advice is a courtesy printed next to a deploy, and BuildKit is the authority on whether a Dockerfile builds. A parser branch that is wrong must produce *fewer* findings, never an exception and never a wrong line number.

*A rule with no **Proven by** line has no test that pins that specific behaviour — the gap is real, not an omission.*

### A heredoc whose delimiter never arrives consumes nothing at all
- **Holds because:** `RUN printf '%s' '<<EOF'` is a shell word, not a heredoc, and so is a typo'd delimiter. Consuming to the end of the file would fold every later instruction into that one and lose every finding after it. `append_heredocs` scans ahead for the delimiter and returns `[ text, index ]` — the index it was *entered* with — when it cannot find one.
- **Where:** `lib/dash/dockerfile/parser.rb#append_heredocs` (lines 107-125)
- **Safe direction:** the whole heredoc body parses as nonsense instructions of its own, which produce no findings; the alternative silently blinds the rest of the file.
- **Proven by:** `test/dockerfile/parser_test.rb:157` ("an unterminated heredoc does not swallow the rest of the file", with the quoted-token input)
- **Origin:** cubic learnings 01552777, 9a9f188e; PR #157

### Two heredocs on one instruction with the second delimiter missing leave *both* unconsumed
- **Holds because:** the recovery returns the method-entry index, not the cursor that already walked past the first body. Consuming the first would leave the parse sitting mid-file in a heredoc, which is the failure the previous rule exists to prevent, one heredoc later.
- **Where:** `lib/dash/dockerfile/parser.rb#append_heredocs` — `at` is a local; the two `return`s both hand back `index`
- **Proven by:** `test/dockerfile/parser_test.rb:164` ("a missing later delimiter leaves the earlier heredoc unconsumed too")
- **Origin:** PR #157

### Inside a heredoc body, a line ending in `\` is the same command as the next one
- **Holds because:** the body is stored line by line so the apt rules can treat each line of a `RUN <<EOF` as its own command — which means a continued `apt-get install \` / `curl ca-certificates` would otherwise read as a segment with an apt operation and a segment without one, and apt-hygiene would report on half a command. `heredoc_commands` joins them before the body is appended.
- **Where:** `lib/dash/dockerfile/parser.rb#heredoc_commands` (lines 129-137)
- **Proven by:** `test/dockerfile/analyzer_test.rb:309` ("a heredoc RUN may continue an apt command with a backslash")
- **Origin:** PR #157

### A registry port stays in the image name; only the last path segment can contribute a tag
- **Holds because:** `localhost:5000/app` has a colon and no tag. Reading `5000/app` as the tag makes `latest-base` silent on a base that really is unpinned. `IMAGE_REF` consumes `(?:[^/@\s]+/)*` path segments before the optional `:tag`, so a colon in any earlier segment belongs to the image.
- **Where:** `lib/dash/dockerfile/stage.rb::IMAGE_REF`
- **Proven by:** `test/dockerfile/parser_test.rb:150` ("a registry port is part of the image, not the tag")
- **Origin:** cubic learning b27307ad; PR #157

### Only interpolation in the *tag* pins a base image; interpolation in the image name does not
- **Holds because:** `FROM ruby:$RUBY_VERSION` is pinned somewhere the parser cannot see, so warning would be noise. `FROM $REGISTRY/app:latest` is not pinned at all, and letting a registry variable suppress it would hide a real unpinned base. `interpolated_tag?` is scoped to `tag`; an explicit `:latest` warns whatever precedes it, and an interpolated image with *no* tag still passes because `$IMAGE` may carry one.
- **Where:** `lib/dash/dockerfile/stage.rb#interpolated_tag?`, read by `Rules::LatestBase#finding_for`
- **Proven by:** `test/dockerfile/parser_test.rb:143`; `test/dockerfile/analyzer_test.rb:53`, `:184`
- **Origin:** cubic learning c43084d6; PR #157

### Only a stage with an explicit `AS` name can be inherited from
- **Holds because:** `stage-N` labels are dash's own, invented for stages the operator did not name. If one collided with a base image name, the shipped-stage walk would mark the wrong stage shipped and move every apt and USER finding onto an image nobody runs. `Stage#named?` gates the inheritance map.
- **Where:** `lib/dash/dockerfile/parser.rb#mark_shipped` (lines 190-198), `lib/dash/dockerfile/stage.rb#named?`
- **Proven by:** `test/dockerfile/parser_test.rb:173` ("only an explicit AS name can be inherited from")
- **Origin:** cubic learning b4858194; PR #157

### `Document#each_instruction` upcases the name it is given
- **Holds because:** the parser normalises keywords to upper case (`from alpine` is a `FROM`), so a rule calling `each_instruction("ARG")` and one calling `each_instruction(:arg)` must find the same instructions. The lookup name is upcased, not the stored one.
- **Where:** `lib/dash/dockerfile/document.rb#each_instruction` (lines 22-27)
- **Proven by:** `test/dockerfile/parser_test.rb:4` pins the normalisation; no test calls `each_instruction` with a lowercase name
- **Origin:** cubic learning 361a0d4c; PR #157

### apt's verb is found past its options, and a shell separator is never an option or an option's value
- **Holds because:** apt takes options before or after the verb (`apt-get -y install`, `apt-get -t bookworm-backports install`), so a pattern anchored on `apt-get\s+install` misses half of real Dockerfiles. But `APT_OPTIONS` stepping over anything would make `apt-get -y && install` an apt install — and, before the fix, made `problems_in` raise on it. `[^\s;&|]` excludes separators from both the option token and its one optional non-dash value, and `problems_in` returns `[]` when no segment holds an apt operation at all, so the rule cannot take the rest of the advice down with it.
- **Where:** `lib/dash/dockerfile/context.rb::APT_OPTIONS`, `::APT_INSTALL`; `lib/dash/dockerfile/rules/apt_hygiene.rb::APT_OPERATION`, `#problems_in`
- **Safe direction:** a quoted apt option value containing `;`, `&` or `|` loses one informational note. That was reviewed and left: the fix is a quote-aware tokenizer the rest of the parser does not have.
- **Proven by:** `test/dockerfile/analyzer_test.rb:197` ("apt rules see apt-get's global option form"), `:274` ("an option that takes a value before the verb"), `:303` ("a shell separator is not an apt option, and no rule raises on the attempt")
- **Origin:** cubic learning 822e63fb; PR #157

### A buildx vertex with no stage name matches a Dockerfile instruction only when the file has exactly one stage
- **Holds because:** buildx omits the stage label only for a single-stage build. Accepting an unnamed vertex anywhere else lets a step from one stage quote another stage's seconds. `same_stage?` returns `document.stages.one?` for a nil step stage and demands an exact name match otherwise.
- **Where:** `lib/dash/dockerfile/context.rb#same_stage?` (lines 129-131)
- **Proven by:** `test/dockerfile/analyzer_test.rb:256` ("a single-stage build's steps carry no stage name and still match")
- **Origin:** cubic learning 87c5a390; PR #157

### An exact normalised match beats any prefix match, whatever `MINIMUM_STEP_MATCH` says
- **Holds because:** buildx expands `${…}` in the vertex names it prints, so exact matching alone is not enough — hence the longest-shared-prefix fallback with a 12-character floor. But `RUN bundle install` and `RUN bundle install --jobs 4` share a long prefix, so a pure prefix ranking hands the shorter instruction the longer step's seconds. Candidates rank `[exact match, shared prefix length, seconds]`.
- **Where:** `lib/dash/dockerfile/context.rb#build_step_for` (lines 95-109)
- **Proven by:** `test/dockerfile/analyzer_test.rb:249` ("a short instruction still matches its build step exactly"), `:295` ("an exact build step wins over a longer one that shares its prefix")
- **Origin:** cubic learnings d17b0e17, 495a905a; PR #157

### When two candidate steps tie, the one with the most seconds wins
- **Holds because:** a multi-platform build reports the same instruction once per platform. Quoting whichever buildx happened to print first understates the cost on the slow platform, which is the one the operator is waiting for.
- **Where:** `lib/dash/dockerfile/context.rb#build_step_for` — `seconds` is the last element of the ranking key
- **Proven by:** `test/build/progress_parser_test.rb:85` pins the per-platform split; no analyzer test pins the tie-break directly
- **Origin:** cubic learning 495a905a; PR #157

### A `COPY`/`ADD` in exec form has its sources read out of `argv`, not out of the raw args string
- **Holds because:** `COPY ["." , "/app"]` is a broad copy, and reading `args` verbatim would see one JSON blob and no `.`. `sources` branches on `json?`.
- **Where:** `lib/dash/dockerfile/context.rb#sources`, `#broad_copy?`; `lib/dash/dockerfile/instruction.rb#json?`, `#argv`
- **Proven by:** `test/dockerfile/analyzer_test.rb:214` ("a JSON-form COPY of the tree is a broad copy")
- **Origin:** PR #157

### Malformed JSON in an exec form is treated as the shell form, never raised
- **Holds because:** BuildKit would reject the file, so the analyzer is looking at something that will not build; taking the deploy's advice block down with a `JSON::ParserError` helps nobody. `#argv` rescues `JSON::ParserError` to nil and `#json?` is then false.
- **Where:** `lib/dash/dockerfile/instruction.rb#argv`
- **Proven by:** no dedicated test
- **Origin:** PR #157

### `.dockerignore` patterns have `./`, `/` and `**/` stripped before matching, and negations are skipped
- **Holds because:** `./node_modules`, `/node_modules` and `node_modules` are one pattern as far as an operator is concerned, and `dockerignore-gaps` comparing the literal text would report a gap that is not there. Negations (`!keep.txt`) are dropped rather than applied.
- **Where:** `lib/dash/dockerfile/dockerignore.rb#initialize`, `#covers?`
- **Safe direction:** skipping negations means a path this says is covered might still ship — one missing finding, never a false accusation.
- **Proven by:** `test/dockerfile/analyzer_test.rb:220` ("dockerignore patterns may carry a ./ prefix")
- **Origin:** cubic learning cade6484; PR #157

### Not a bug: the exec form is matched as joined shell text
- **Holds because:** `Instruction#shell_command` joins `argv` with spaces, so a rule matching shell syntax sees text that never goes through a shell. A false positive needs shell metacharacters *inside a single exec-form argument*, and the only two rules that could trip on it — `curl-pipe-shell` and `inline-env-blob` — are informational. The alternative is teaching every rule two forms.
- **Where:** `lib/dash/dockerfile/instruction.rb#shell_command`
- **Origin:** PR #157 (suggestion declined with this reasoning)
