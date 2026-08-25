# Testing Rules

## TDD Workflow

Follow RED -> GREEN -> REFACTOR:

1. **RED**: Write a failing test first
2. **GREEN**: Write minimal code to pass
3. **REFACTOR**: Improve code while keeping tests green

## Coverage Requirements

- **80% minimum** for all code
- **100% required** for:
  - `Dash::Configuration::Proxy::Run` (`MINIMUM_VERSION`, repository defaults)
  - `Dash::Commander` (target/role resolution)
  - `Dash::Configuration` (deploy.yml parsing, validation)
  - `Dash::Commands::Proxy` / loadbalancer auto-activation logic
  - `Dash::Cli::Main` hooks (before/after deploy)

## Test Type Preference

| Feature involves | Use |
|---|---|
| `Dash::Configuration::*` (deploy.yml -> objects) | Unit test |
| `Dash::Commands::*` (docker command string builders) | Unit test, assert generated shell command |
| `Dash::Cli::*` (Thor commands) | Unit test with `SSHKit::Backend::Printer` (see `test_helper.rb`) |
| `Dash::Commander` | Unit test |
| Proxy boot / loadbalancer activation | Unit test in `test/commands/proxy_test.rb`, `test/commands/loadbalancer_test.rb` |
| Full deploy against real hosts | Integration test (`test/integration/**`) |
| `bin/dash` entry point | Not unit tested — covered by integration |

## Minitest + Mocha Conventions (NOT RSpec)

This repo uses `ActiveSupport::TestCase` + Minitest `test "..." do...end` blocks + `mocha/minitest`, not RSpec. No `let`, no `describe`/`it`, no `double`.

```ruby
require "test_helper"

class ConfigurationProxyRunTest < ActiveSupport::TestCase
  setup do
    ENV["RAILS_MASTER_KEY"] = "456"
    ENV["VERSION"] = "missing"
  end

  test "run objects with identical config are equal" do
    deploy = base_deploy.deep_merge(proxy: { "run" => { "log_max_size" => "50m" } })
    config = Dash::Configuration.new(deploy)

    run_a = Dash::Configuration::Proxy::Run.new(config, run_config: { "log_max_size" => "50m" })
    run_b = Dash::Configuration::Proxy::Run.new(config, run_config: { "log_max_size" => "50m" })

    assert_equal run_a, run_b
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

- Use `Class.any_instance.stubs(:method)` / `.expects(:method)` for Mocha doubles — see `SecretAdapterTestCase#stub_ticks` in `test/test_helper.rb`
- Use `assert_equal`, `assert_not_equal`, `assert`, `refute` — not `expect().to`
- No real SSH: `test_helper.rb` swaps in `SSHKit::Backend::Printer`, which prints instead of executing. Assert against the printed command string.
- No real secrets/PostgreSQL/network in unit tests — everything runs against fixtures under `test/fixtures/`

## Interpolate MINIMUM_VERSION — Never Hardcode Proxy Versions

Fork-specific: proxy image tags are fork-owned (`ghcr.io/zoolutions/dash-proxy:v0.9.2.1`) and change independently of the gem. Tests must reference `Dash::Configuration::Proxy::Run::MINIMUM_VERSION`, never a literal version string:

```ruby
# Correct
assert_match %r{ghcr\.io/zoolutions/dash-proxy:#{Dash::Configuration::Proxy::Run::MINIMUM_VERSION}}, cmd

# Wrong — breaks every time the proxy fork releases
assert_match %r{ghcr\.io/zoolutions/dash-proxy:v0\.9\.2\.1}, cmd
```

See `.claude/rules/upstream-sync.md` for why this constant moves and how releases are ordered (proxy image before gem).

## Unit vs Integration Split

| | Unit (`test/**` minus `test/integration`) | Integration (`test/integration/**`) |
|---|---|---|
| Needs Docker | No | Yes — Docker-in-Docker deployer VMs |
| Needs proxy image | No | Yes — pulls `ghcr.io/zoolutions/dash-proxy:$MINIMUM_VERSION`; fails if unpublished |
| Speed | Fast, run constantly | Slow, run before pushing `main` / releasing |
| Command | `bundle exec ruby -Itest -e 'Dir["test/**/*_test.rb"].grep_v(/integration/).each { |f| require File.expand_path(f) }'` | `bin/test` (runs everything, unit + integration) |

Run unit tests continuously during TDD. Run `bin/test` (full suite) before pushing `main` and always before `rake release`, per `.claude/rules/upstream-sync.md`.

## Known Arch-Dependent Failures

Two tests in `test/commands/builder_test.rb` compare against the *local* Docker buildx arch (`local_arch`/`remote_arch` helpers) and **fail on Apple Silicon** — they pass in CI and on a pristine `amd64` runner. Do not "fix" them by changing assertions; this is a pre-existing host-arch artifact, not a regression. Confirm any builder-test failure is one of these two before investigating further:

```bash
bundle exec ruby -Itest test/commands/builder_test.rb 2>&1 | grep -A3 "target remote when\|target local when"
```

## New Multi-Host Fixtures

If a deploy fixture under `test/fixtures/` gets a primary role with more than one host, add `loadbalancer: false` under its `proxy:` key. The fork auto-activates the loadbalancer for any primary role with >1 web host, which the Docker-in-Docker integration harness can't support (inner VM hostnames don't resolve inside the nested docker network). This applies whether the fixture is new or inherited from an upstream sync — see the conflict playbook in `.claude/rules/upstream-sync.md`.

## Test Checklist

- [ ] Tests written BEFORE implementation
- [ ] Unit tests pass: `bundle exec ruby -Itest -e 'Dir["test/**/*_test.rb"].grep_v(/integration/).each { |f| require File.expand_path(f) }'`
- [ ] `bundle exec rubocop --parallel` clean
- [ ] Full suite passes before pushing `main` or releasing: `bin/test`
- [ ] Any proxy version in an assertion is `Dash::Configuration::Proxy::Run::MINIMUM_VERSION`, not a literal
- [ ] New multi-host fixtures set `loadbalancer: false` if not testing that feature
- [ ] Builder-test failures checked against the two known Apple-Silicon cases before treating as a bug
- [ ] Coverage meets requirements (80% / 100% for critical-path components above)
