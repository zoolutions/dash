# frozen_string_literal: true

# dash app rollout deploy|set|stop — the cookie-keyed canary that dash-proxy
# implements and dash exposes; upstream kamal has no gem surface for it.
class Views::Docs::Pages::CanaryRollout < DocsUI::Page
  title "Canary rollout"
  eyebrow "Deploying"

  def lead = "Run a new version next to the live one and send it a slice of traffic before you commit."

  def content
    lifecycle
    how_it_routes
    with_loadbalancer
    ending
  end

  private

  def lifecycle
    DocsUI::Section("Lifecycle") do
      md <<~'MD'
        A normal `dash deploy` replaces the live version. A rollout starts a
        second version alongside it, registered with dash-proxy as the
        service's **rollout target**, and lets you decide how much traffic it
        sees. Three subcommands, in order:
      MD
      DocsUI::Code(<<~SHELL, lexer: :shell)
        dash app rollout deploy                      # boot the newest image as the rollout target
        dash app rollout deploy --version 3f9c2a1    # or a specific version
        dash app rollout set --percent 10            # 10% of cookie-carrying traffic
        dash app rollout set --list beta,qa-team     # plus everyone whose cookie is one of these
        dash app rollout stop                        # all traffic back to the live version
      SHELL
      md <<~'MD'
        `rollout deploy` builds nothing — it takes the most recent image already
        in the registry (or `--version`), takes the deploy lock, and on every
        proxy host boots that version's container for each proxied role, then
        registers it with `kamal-proxy rollout deploy`. dash-proxy waits up to
        `deploy_timeout` for the new target to become healthy, exactly as it
        does for a normal deploy, and the boot fails (and the container is
        stopped) if it does not. Booting a version that is already deployed on
        the host is refused.

        Until you run `rollout set`, the target is registered but receives
        **no** traffic. `set` takes `--percent`, `--list`, or both; running it
        before `deploy` fails with "rollout target not set".
      MD
    end
  end

  def how_it_routes
    DocsUI::Section("How dash-proxy picks a target") do
      md <<~'MD'
        Routing is keyed on one cookie, `kamal-rollout`. For each request:

        1. No `kamal-rollout` cookie → the live version. Always.
        2. The cookie's value is in `--list` → the rollout target.
        3. Otherwise the value is hashed (FNV-1a) and lands in the rollout
           target if the hash falls below `--percent`% of the hash space.

        Two consequences worth designing around. First, **your app sets the
        cookie** — dash-proxy never does. Set it to something stable per user
        or per session and the same person sees the same version on every
        request; leave it unset and nobody is ever routed to the canary. Second,
        the split is deterministic on the cookie value, not random per request,
        so `--percent 10` means "the 10% of values whose hash is lowest",
        which is the same 10% of people across the whole rollout.

        The rollout target is a full target of the service: it is health
        checked, drained on stop, and shares the live service's host, TLS,
        buffering, and logging options — `rollout deploy` accepts only the
        target and the timeouts.
      MD
    end
  end

  def with_loadbalancer
    DocsUI::Section("With a load balancer") do
      md <<~'MD'
        `rollout` runs on the proxy hosts, for roles that run the proxy. With
        the [load balancer](/docs/load-balancing) in front of the fleet, the
        rollout target is registered on each per-host proxy next to its live
        container, and the load balancer keeps distributing across hosts as
        before. The cookie decision is made on the per-host proxy, so the
        canary share is per host: `--percent 10` on three hosts is 10% on each,
        not 10% of one.
      MD
    end
  end

  def ending
    DocsUI::Section("Ending a rollout") do
      md <<~'MD'
        `rollout stop` clears the traffic split: every request goes to the
        live version again. The canary container keeps running and stays
        registered as the rollout target, so `rollout set` can resume the
        experiment without a new boot.

        To promote the canary, deploy it: `dash deploy` (or
        `dash app boot --version <canary>`) runs the normal boot for that
        version — the existing container of that version is renamed out of the
        way, the new one becomes the live target, and the previous live version
        is stopped. Run `rollout stop` first so the split is not left pointing
        at a target that is about to be replaced, and `dash prune containers`
        to clear the stopped ones afterwards.
      MD
      DocsUI::Callout(:warning) do
        plain "A rollout is not ended by deploying something else. The split survives an unrelated "
        code { "dash deploy" }
        plain " of a third version — stop it explicitly."
      end
    end
  end
end
