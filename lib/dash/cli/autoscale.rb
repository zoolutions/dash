# `dash autoscale`: the controller that holds each scheduled role at its target
# (Dash::Autoscale::Controller), and the commands that read what it decided and why. The
# controller's state lives on the primary host, so every operator's checkout reads the
# same heartbeat, decisions and pauses.
class Dash::Cli::Autoscale < Dash::Cli::Base
  MINIMUM_INTERVAL = 5
  LOCK_WAIT_INTERVAL = 5

  # `run` is a Thor reserved word, so the method has another name.
  map "run" => :start_controller

  desc "run", "Run the autoscale controller: every interval, scale each role with a scale/schedule to its target through dash scale set"
  option :once, type: :boolean, default: false, desc: "Run one tick and exit (for cron)"
  option :dry_run, type: :boolean, default: false, desc: "Decide and print, without acting or writing any state"
  option :interval, type: :numeric, desc: "Seconds between ticks (default autoscale/interval)"
  option :metrics_port, type: :numeric, desc: "Serve Prometheus metrics on this port at /metrics"
  option :metrics_bind, default: "127.0.0.1", desc: "Address the metrics endpoint binds"
  option :record, desc: "Append every tick's decisions, with their inputs, to this local JSONL file"
  option :takeover, type: :boolean, default: false, desc: "Start even while another controller's heartbeat is alive (it stops at its next tick)"
  def start_controller
    raise ArgumentError, "dash autoscale run works on whole roles: narrow it with --roles, not --hosts or --primary" if options[:hosts] || options[:primary]

    controller = Dash::Autoscale::Controller.new(cli: self, dry_run: options[:dry_run], takeover: options[:takeover], interval: tick_interval,
      mode: options[:once] ? "once" : "loop", recorder: (Dash::Autoscale::Recorder.new(options[:record]) if options[:record]))
    pre_connect_if_required

    options[:once] ? run_once(controller) : run_loop(controller)
  end

  desc "explain ROLE", "Evaluate ROLE as the controller's next tick would, with every input, without acting"
  option :json, type: :boolean, default: false, desc: "Print the evaluation as JSON"
  def explain(role_name)
    role = scaled_role(role_name)
    explain = -> { Dash::Diagnostics::AutoscaleExplain.new(role: role).to_h }

    if options[:json]
      puts_json(&explain)
    else
      pre_connect_if_required
      print_explain(DASH.with_verbosity(:error) { explain.call })
    end
  end

  desc "history [ROLE]", "Show the controller's last decisions (of ROLE, or of every role)"
  option :lines, type: :numeric, default: Dash::Diagnostics::AutoscaleDecisions::DEFAULT_LINES, desc: "How many decisions"
  option :json, type: :boolean, default: false, desc: "Print the decisions as JSON"
  def history(role_name = nil)
    role = scaled_role(role_name).name if role_name
    history = -> { Dash::Diagnostics::AutoscaleDecisions.new(role: role, lines: options[:lines]).to_h }

    if options[:json]
      puts_json(&history)
    else
      pre_connect_if_required
      print_history(DASH.with_verbosity(:error) { history.call })
    end
  end

  desc "status", "Show which controller runs, when it last ticked, and the paused roles"
  option :json, type: :boolean, default: false, desc: "Print the status as JSON"
  def status
    status = -> { Dash::Diagnostics::ControllerStatus.new.to_h }

    if options[:json]
      puts_json(&status)
    else
      pre_connect_if_required
      print_status(DASH.with_verbosity(:error) { status.call })
    end
  end

  desc "pause ROLE", "Stop the controller from scaling ROLE, for good or --for a while (resume ROLE lifts it)"
  option :for, desc: "How long: seconds, or a number followed by s, m, h or d (30m, 2h, 1d)"
  def pause(role_name)
    role = scaled_role(role_name)
    now = Time.now.utc
    ends_at = options[:for] ? now + pause_duration(options[:for]) : :indefinite
    pause = Dash::Autoscale::Pause.new(ends_at: ends_at, by: performer, at: now)
    until_text = pause.indefinite? ? "until resumed" : "until #{Dash::Autoscale::Timestamp.dump(ends_at)}"

    on(Dash::Autoscale::StateStore.host) do
      store = Dash::Autoscale::StateStore.new(self)
      store.ensure_directory
      store.write_pause(role.name, pause.to_h)
      execute *DASH.auditor.record("Paused autoscaling of #{role} #{until_text}"), verbosity: :debug
    end

    say "Paused autoscaling of #{role} #{until_text}", :magenta
  end

  desc "resume ROLE", "Let the controller scale ROLE again"
  def resume(role_name)
    role = scaled_role(role_name)

    on(Dash::Autoscale::StateStore.host) do
      Dash::Autoscale::StateStore.new(self).remove_pause(role.name)
      execute *DASH.auditor.record("Resumed autoscaling of #{role}"), verbosity: :debug
    end

    say "Resumed autoscaling of #{role}", :magenta
  end

  # What Dash::Autoscale::Controller asks of the CLI.
  no_commands do
    # A fresh deploy.yml every tick, as `dash mcp` reads one per question, with the run's
    # --roles applied again (reconfigure drops them).
    def reconfigure!
      roles = options[:roles]&.split(",")
      DASH.reconfigure(config_file: Pathname.new(File.expand_path(options[:config_file])), destination: options[:destination], explicit_roles: roles)
      DASH.specific_roles = roles
    end

    # `dash scale set ROLE COUNT`, waiting up to autoscale/lock_wait_timeout for the deploy
    # lock. The invocation is reset even when it fails, or Thor would skip the next one.
    def invoke_scale_set(role, count)
      with_lock_wait do
        invoke "dash:cli:scale:set", [ role.name, count.to_s ], scale_options
      ensure
        reset_invocation(Dash::Cli::Scale)
      end
    end

    def replace_member(role, member, count:)
      with_lock_wait do
        Dash::Cli::Scale.new([], scale_options, invocations: { Dash::Cli::Scale => [ "set" ] }).replace_unreachable(role, member, count: count)
      end
    end

    def report(message, color = nil)
      say message, color
    end
  end

  private
    # A signal during the tick lets it finish (a join in flight included), then it exits.
    def run_once(controller)
      trapping_signals(controller) do
        controller.start
        controller.tick
      end
    ensure
      controller.release
    end

    def run_loop(controller)
      server = Dash::Autoscale::MetricsServer.new(controller.metrics, bind: options[:metrics_bind], port: options[:metrics_port]).start if options[:metrics_port]
      say "Serving autoscale metrics on http://#{options[:metrics_bind]}:#{server.port}/metrics", :magenta if server
      say "Autoscale controller #{controller.id}#{" (dry run)" if options[:dry_run]} ticking every #{controller.interval}s", :magenta

      trapping_signals(controller) { controller.run }
    ensure
      server&.stop
    end

    # TERM and INT only ask the controller to stop: the tick in progress, and a join in it, finish.
    def trapping_signals(controller)
      previous = %w[ TERM INT ].to_h { |signal| [ signal, trap(signal) { controller.stop! } ] }
      yield
    ensure
      previous&.each { |signal, handler| trap(signal, handler || "DEFAULT") }
    end

    def tick_interval
      return unless options[:interval]

      interval = Integer(options[:interval].to_s, 10, exception: false)
      if interval.nil? || interval < MINIMUM_INTERVAL
        raise ArgumentError, "--interval must be a whole number of seconds, at least #{MINIMUM_INTERVAL}, not #{options[:interval]}"
      end

      interval
    end

    def with_lock_wait
      saved = [ DASH.lock_wait, DASH.lock_wait_timeout, DASH.lock_wait_interval ]
      DASH.lock_wait, DASH.lock_wait_timeout, DASH.lock_wait_interval = true, DASH.config.autoscale.lock_wait_timeout, LOCK_WAIT_INTERVAL
      yield
    ensure
      DASH.lock_wait, DASH.lock_wait_timeout, DASH.lock_wait_interval = saved
    end

    def scale_options
      options.slice("config_file", "destination", "skip_hooks", "verbose", "quiet")
    end

    def scaled_role(role_name)
      role = DASH.config.role(role_name) || raise(ArgumentError, "No role named #{role_name}, expected one of #{DASH.config.roles.map(&:name).join(", ")}")
      raise ArgumentError, "#{role} has no scale, so the autoscale controller never touches it" unless role.scaled?

      role
    end

    def pause_duration(value)
      seconds = Dash::Autoscale::Duration.parse(value)
      raise ArgumentError, "--for must be longer than 0 seconds" unless seconds.positive?

      seconds
    end

    def performer
      Dash::Git.user_name.presence || ENV["USER"] || "unknown"
    end

    def print_explain(explain)
      decision = explain[:decision]
      say "#{decision[:role]}: #{decision[:action]} #{decision[:from].inspect} -> #{decision[:to].inspect} (#{decision[:reasons].join(", ")})"
      say "  not controlled: it has no scale/schedule, so dash autoscale run leaves it alone", :yellow unless explain[:controlled]
      say "  error: #{decision[:error]}", :red if decision[:error]
      say "  eligible at: #{decision[:eligible_at]}" if decision[:eligible_at]
      decision[:inputs].each { |name, value| say "  #{name}: #{value.to_json}" unless value.nil? || value == [] || value == {} }
      say "  state on #{explain[:state_host]} could not be read (#{explain[:state_error]}), evaluated without it", :yellow if explain[:state_error]
    end

    def print_history(history)
      return say("Could not read the decision log on #{history[:host]}: #{history[:error]}", :red) if history[:error]
      return say("No autoscale decisions logged yet") if history[:decisions].empty?

      history[:decisions].each do |decision|
        counts = decision["action"] == "replace_member" ? decision.dig("inputs", "replace") : "#{decision["from"].inspect} -> #{decision["to"].inspect}"
        error = " - #{decision["error"]}" if decision["error"]
        say "#{decision["at"]}  #{decision["role"]}: #{decision["action"]} #{counts} (#{decision["reasons"].to_a.join(", ")})#{error}", (:red if error)
      end
    end

    def print_status(status)
      return say("Could not read the controller state on #{status[:state_host]}: #{status[:error]}", :red) if status[:error]

      if (controller = status[:controller])
        tick = controller[:age_seconds] ? "last tick #{controller[:age_seconds]}s ago" : "no tick yet"
        say "Controller #{controller[:controller_id]} on #{controller[:hostname]} (pid #{controller[:pid]}, dash #{controller[:version]}, #{controller[:mode]}): " \
          "#{controller[:status]}, #{tick}", controller[:status] == "running" ? :green : :yellow
      else
        say "No autoscale controller has run for this app", :yellow
      end

      say "Scheduled roles: #{status[:roles].any? ? status[:roles].join(", ") : "none"}"
      status[:pauses].each { |pause| say "#{pause[:role]} paused #{pause[:until] == "indefinite" ? "until resumed" : "until #{pause[:until]}"} by #{pause[:by]}", :yellow }
    end
end
