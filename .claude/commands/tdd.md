---
description: "Use when implementing any feature or fixing any bug -- enforces RED-GREEN-REFACTOR: write failing test first, implement minimum code to pass, then refactor."
model: sonnet
argument-hint: "[file-or-class, e.g. lib/kamal/configuration/proxy/run.rb]"
allowed-tools: Read, Write, Edit, Bash(bundle exec ruby*), Bash(bundle exec rubocop*), Bash(bin/test*), Bash(git diff*), Bash(git status*)
---

# TDD Command

Enforce test-driven development with RED -> GREEN -> REFACTOR. Never write implementation before a failing test exists for it.

## The TDD Cycle

```text
RED -> GREEN -> REFACTOR -> REPEAT

RED:      Write a failing test (test MUST fail first)
GREEN:    Write MINIMAL code to pass (nothing more)
REFACTOR: Improve code while keeping tests green
REPEAT:   Next scenario
```

## When to Use

- Implementing new Thor commands (`Kamal::Cli::*`) or `Kamal::Commands::*` builders
- Adding Configuration objects or options under `lib/kamal/configuration/`
- Fixing bugs — write the test that reproduces the bug FIRST
- Touching the loadbalancer auto-activation path (`lib/kamal/configuration/proxy/`)
- Refactoring anything in the layer cake (see `CLAUDE.md` Architecture)

**NOT for**: `kamal.gemspec`, `bin/release` — upstream-owned files, never edited (see `.claude/rules/upstream-sync.md`).

## Workflow

### Step 1: Write Failing Tests (RED)

This repo uses **Minitest + Mocha**, not RSpec. Match the existing style: `ActiveSupport::TestCase`, `test "..." do`, `setup`/`teardown` blocks, `assert_equal` / `assert_not_equal`, `SomeClass.any_instance.stubs(:method)`.

```ruby
# test/configuration/proxy/run_test.rb
require "test_helper"

class ConfigurationProxyRunTest < ActiveSupport::TestCase
  setup do
    ENV["RAILS_MASTER_KEY"] = "456"
    ENV["VERSION"] = "missing"
  end

  test "run objects with identical config are equal" do
    deploy = base_deploy.deep_merge(proxy: { "run" => { "log_max_size" => "50m" } })
    config = Kamal::Configuration.new(deploy)

    run_a = Kamal::Configuration::Proxy::Run.new(config, run_config: { "log_max_size" => "50m" })
    run_b = Kamal::Configuration::Proxy::Run.new(config, run_config: { "log_max_size" => "50m" })

    assert_equal run_a, run_b
  end

  test "raises when log_max_size is not a valid docker size" do
    deploy = base_deploy.deep_merge(proxy: { "run" => { "log_max_size" => "bogus" } })

    assert_raises(Kamal::ConfigurationError) { Kamal::Configuration.new(deploy) }
  end

  private
    def base_deploy
      {
        service: "app", image: "dhh/app",
        registry: { "username" => "dhh", "password" => "secret" },
        builder: { "arch" => "amd64" },
        servers: [ "1.1.1.1" ]
      }
    end
end
```

### Step 2: Run Tests — Verify FAIL

Run only the file you're working on, unit-scoped (no Docker):

```bash
bundle exec ruby -Itest test/configuration/proxy/run_test.rb

# NameError: uninitialized constant / Expected behavior not met
```

**Tests MUST fail before implementing.** This confirms:
- The test is actually running (typos in class/method names silently no-op in Minitest too)
- The test targets the right behavior
- The implementation doesn't already exist

### Step 3: Implement Minimal Code (GREEN)

Write the minimum code in the target class to make the test pass — e.g. add a guard clause in `Kamal::Configuration::Proxy::Run#log_max_size`, not a whole new abstraction.

### Step 4: Run Tests — Verify PASS

```bash
bundle exec ruby -Itest test/configuration/proxy/run_test.rb

# N runs, N assertions, 0 failures, 0 errors
```

### Step 5: Refactor (IMPROVE)

Improve code while keeping tests green:
- Extract private methods to reduce complexity (see `format_bind_ip` in `run.rb` for the house pattern)
- Improve naming
- Reduce duplication
- Keep `Configuration` objects immutable-by-convention (`==`/`hash` defined off `run_config`, no mutation after `initialize`)

### Step 6: Run the Unit Suite

Fast loop — everything except `test/integration` (no Docker, no proxy image):

```bash
bundle exec ruby -Itest -e 'Dir["test/**/*_test.rb"].grep_v(/integration/).each { |f| require File.expand_path(f) }'
```

### Step 7: Lint

```bash
bundle exec rubocop --parallel
```

### Step 8: Full Suite Before Pushing

Only when the change touches deploy/proxy/boot flow — needs Docker and the published proxy image (`ghcr.io/mhenrixon/kamal-proxy:$MINIMUM_VERSION`):

```bash
bin/test
```

Two builder tests are known-failing on Apple Silicon only (host-arch dependent); they pass in CI. Don't chase them.

## Coverage Requirements

| Code Type | Minimum Coverage |
|-----------|------------------|
| All code | 80% |
| `Kamal::Configuration::*` (deploy.yml validation) | 100% |
| `Kamal::Commands::*` (docker command builders) | 100% |
| `Kamal::Cli::*` (Thor commands, hooks) | 100% |
| Proxy defaults (`lib/kamal/configuration/proxy/`) | 100% |

## Test Types to Include

### Unit Tests (Configuration, Commands, Utils)
- Happy path scenarios
- Edge cases (nil values, missing hosts, malformed `deploy.yml` fragments)
- Error conditions (`Kamal::ConfigurationError`)

### CLI Tests (`test/cli/*_test.rb`)
- Thor command invocation and option parsing
- Hook firing order
- `SSHKit::Backend::Printer` captures the commands that *would* run — assert against `sshkit.stdout`/`capture_io`, don't hit the network

### Integration Tests (`test/integration/*_test.rb`)
- Real deploys against Docker-in-Docker VMs
- Proxy boot/reboot lifecycle
- Loadbalancer auto-activation (only fires for primary role with >1 web host — see `.claude/rules/upstream-sync.md` conflict playbook for why multi-host fixtures need `loadbalancer: false`)

## Best Practices

**DO:**
- Write the test FIRST, before any implementation
- Run tests and verify they FAIL before implementing
- Write MINIMAL code to make tests pass
- Refactor only after tests are green
- Interpolate `Kamal::Configuration::Proxy::Run::MINIMUM_VERSION` in assertions — never hardcode a proxy tag (see `CLAUDE.md` Critical Rules #3)
- Use `AnyClass.any_instance.stubs(:method)` for boundaries you don't own (network, threads, `sleep`) — mirror `test/otel_shipper_test.rb`

**DON'T:**
- Write implementation before tests
- Skip running the unit suite after each change
- Write too much code at once
- Ignore failing tests
- Test private/implementation details — test the public behavior of the Configuration/Command object
- Skip testing error paths (`Kamal::ConfigurationError`, `SSHKit::Runner::ExecuteError`)
- Edit `kamal.gemspec` or `bin/release` to make a test pass — those are upstream-owned; fix `dash.gemspec`/`bin/release-dash` or the actual bug instead

## Checklist

- [ ] Tests written BEFORE implementation
- [ ] Tests fail initially (RED phase verified)
- [ ] Minimal code written to pass (GREEN)
- [ ] Code refactored with tests still passing
- [ ] Coverage meets requirements (80%+, 100% for Configuration/Commands/Cli)
- [ ] All edge cases and error paths covered
- [ ] `bundle exec rubocop --parallel` clean
- [ ] Unit suite green; `bin/test` run if proxy/deploy/boot flow touched
- [ ] No edits to upstream-owned files (`kamal.gemspec`, `bin/release`)
