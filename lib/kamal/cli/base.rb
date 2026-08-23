require "thor"
require "kamal/sshkit_with_ext"

module Kamal::Cli
  class Base < Thor
    include SSHKit::DSL

    VERBOSITY = { verbose: :debug, quiet: :error }.freeze
    AUTOMATIC_DEPLOY_LOCK_MESSAGE = "Automatic deploy lock"

    class LockHeldError < StandardError; end
    class LockMissingError < StandardError; end

    # Hooks set process-global state (the hook env and the SSHKit verbosity), so
    # serialize them: some fire from inside SSHKit's per-host threads.
    HOOK_MUTEX = Mutex.new

    def self.exit_on_failure?() true end
    def self.dynamic_command_class() Kamal::Cli::Alias::Command end

    class_option :verbose, type: :boolean, aliases: "-v", desc: "Detailed logging"
    class_option :quiet, type: :boolean, aliases: "-q", desc: "Minimal logging"

    class_option :version, desc: "Run commands against a specific app version"

    class_option :primary, type: :boolean, aliases: "-p", desc: "Run commands only on primary host instead of all"
    class_option :hosts, aliases: "-h", desc: "Run commands on these hosts instead of all (separate by comma, supports wildcards with *)"
    class_option :roles, aliases: "-r", desc: "Run commands on these roles instead of all (separate by comma, supports wildcards with *)"

    class_option :config_file, aliases: "-c", default: "config/deploy.yml", desc: "Path to config file"
    class_option :destination, aliases: "-d", desc: "Specify destination to be used for config file (staging -> deploy.staging.yml)"

    class_option :skip_hooks, aliases: "-H", type: :boolean, default: false, desc: "Don't run hooks"

    class_option :lock_wait, type: :boolean, default: false, desc: "Wait for the deploy lock if it's already held instead of failing immediately"
    class_option :lock_wait_timeout, type: :numeric, default: 900, desc: "Maximum seconds to wait for the deploy lock when --lock-wait is set"
    class_option :lock_wait_interval, type: :numeric, default: 15, desc: "Seconds between deploy lock polls when --lock-wait is set"

    def initialize(args = [], local_options = {}, config = {})
      if config[:current_command].is_a?(Kamal::Cli::Alias::Command)
        # When Thor generates a dynamic command, it doesn't attempt to parse the arguments.
        # For our purposes, it means the arguments are passed in args rather than local_options.
        super([], args, config)
      else
        super
      end

      initialize_commander unless KAMAL.configured?
    end

    # Public so collaborators like Kamal::Cli::App::Boot can fire hooks, but not a Thor command.
    no_commands do
      def run_hook(hook, **extra_details)
        if !options[:skip_hooks] && KAMAL.hook.hook_exists?(hook)
          details = {
            hosts: KAMAL.hosts.join(","),
            roles: KAMAL.specific_roles&.join(","),
            lock: KAMAL.holding_lock?.to_s,
            command: command,
            subcommand: subcommand
          }.compact

          hooks_output = KAMAL.config.hooks_output_for(hook)

          # CLI flags override config: -q hides all, -v shows all
          # Config setting :verbose forces output, :quiet forces silence
          hook_verbosity = if KAMAL.verbosity == :info && hooks_output
            VERBOSITY.fetch(hooks_output)
          else
            KAMAL.verbosity
          end

          HOOK_MUTEX.synchronize do
            with_env KAMAL.hook.env(**details, **extra_details) do
              KAMAL.with_verbosity(hook_verbosity) do
                run_locally do
                  execute *KAMAL.hook.run(hook)
                end
              end
            rescue SSHKit::Command::Failed => e
              raise HookError.new("Hook `#{hook}` failed:\n#{e.message}")
            end
          end
        end
      end
    end

    private
      def options_with_subcommand_class_options
        options.merge(@_initializer.last[:class_options] || {})
      end

      def initialize_commander
        KAMAL.tap do |commander|
          if options[:verbose]
            ENV["VERBOSE"] = "1" # For backtraces via cli/start
            commander.verbosity = VERBOSITY[:verbose]
          end

          if options[:quiet]
            commander.verbosity = VERBOSITY[:quiet]
          end

          commander.configure \
            config_file: Pathname.new(File.expand_path(options[:config_file])),
            destination: options[:destination],
            version: options[:version]

          commander.specific_hosts    = options[:hosts]&.split(",")
          commander.specific_roles    = options[:roles]&.split(",")
          commander.specific_primary! if options[:primary]

          commander.lock_wait          = options[:lock_wait]
          commander.lock_wait_timeout  = options[:lock_wait_timeout]
          commander.lock_wait_interval = options[:lock_wait_interval]
        end
      end

      def print_runtime
        started_at = Time.now
        yield
        Time.now - started_at
      ensure
        runtime = Time.now - started_at
        puts "  Finished all in #{sprintf("%.1f seconds", runtime)}"
      end

      # Deploy lock outside, server lock inside. Every caller acquires in that
      # order, and deploy locks are unique per destination, so no cycle forms.
      def modify(lock: false, server_lock: false)
        KAMAL.modify(command: command, subcommand: subcommand) do
          guarded = -> { server_lock ? with_server_lock { yield } : yield }

          lock ? with_lock(&guarded) : guarded.call
        end
      end

      def say(message = "", *)
        super unless options[:raw]
        KAMAL.log(message.to_s)
      end

      # Raw output is written straight to stdout for piping, so silence SSHKit's
      # command echoing that would otherwise corrupt the byte stream.
      def with_raw_output(raw, &block)
        raw ? KAMAL.with_verbosity(:error, &block) : block.call
      end

      # kamal-proxy is one container per host, shared by every destination
      # deployed there, but the deploy lock is per-destination — so two
      # destinations deploying at once take different locks and both mutate the
      # same proxy. Anything touching the proxy takes this lock as well.
      def with_server_lock
        if KAMAL.holding_server_lock?
          yield
        else
          acquire_server_lock

          begin
            yield
          ensure
            release_server_lock
          end
        end
      end

      # Always waits rather than failing: the guarded work is short, and
      # aborting the second destination would defeat running them in parallel.
      #
      # Hosts are taken one at a time and rolled back on contention. Taking them
      # in one `on(hosts)` sweep would leave the locks we did win in place, and
      # every retry would then collide with itself and wait out the timeout.
      def acquire_server_lock
        ensure_run_directory

        timeout = KAMAL.lock_wait_timeout
        interval = KAMAL.lock_wait_interval
        deadline = Time.now + timeout
        details_shown = false

        say "Acquiring the server lock...", :magenta

        loop do
          held = []

          begin
            server_lock_hosts.each do |host|
              execute_lock_acquire(AUTOMATIC_DEPLOY_LOCK_MESSAGE, lock: KAMAL.server_lock, hosts: host)
              held << host
            end

            break
          rescue LockHeldError
            release_server_lock_on(held)

            unless details_shown
              say "Server lock is held by:", :magenta
              puts capture_lock_status(lock: KAMAL.server_lock, hosts: server_lock_hosts.first)
              details_shown = true
            end

            remaining = (deadline - Time.now).to_i
            if remaining <= 0
              say "Timed out after #{timeout}s waiting for the server lock", :red
              raise LockError, "Timed out waiting for server lock"
            end

            say "Waiting #{interval}s for the server lock (#{remaining}s remaining)...", :magenta
            sleep [ interval, remaining ].min
          end
        end

        KAMAL.holding_server_lock = true
      end

      def release_server_lock
        say "Releasing the server lock...", :magenta
        release_server_lock_on(server_lock_hosts)

        KAMAL.holding_server_lock = false
      end

      # Only ever called with hosts this process actually locked, so a missing
      # directory means someone already cleaned up, not that we may delete
      # another deploy's lock.
      def release_server_lock_on(hosts)
        Array(hosts).each do |host|
          execute_lock_release(lock: KAMAL.server_lock, hosts: host)
        rescue LockMissingError
          nil
        end
      end

      def server_lock_hosts
        KAMAL.proxy_hosts.presence || KAMAL.hosts
      end

      def with_lock
        if KAMAL.holding_lock?
          yield
        else
          acquire_lock

          begin
            yield
          rescue
            begin
              release_lock
            rescue => e
              say "Error releasing the deploy lock: #{e.message}", :red
            end
            raise
          end

          release_lock
        end
      end

      def confirming(question)
        return yield if options[:confirmed]

        if ask(question, limited_to: %w[ y N ], default: "N") == "y"
          yield
        else
          say "Aborted", :red
        end
      end

      def acquire_lock
        ensure_run_directory

        if KAMAL.lock_wait
          acquire_lock_with_wait
        else
          raise_if_locked do
            say "Acquiring the deploy lock...", :magenta
            execute_lock_acquire(AUTOMATIC_DEPLOY_LOCK_MESSAGE)
          end
        end

        KAMAL.holding_lock = true
      end

      def acquire_lock_with_wait
        timeout = KAMAL.lock_wait_timeout
        interval = KAMAL.lock_wait_interval
        deadline = Time.now + timeout
        details_shown = false

        say "Acquiring the deploy lock (waiting up to #{timeout}s)...", :magenta

        loop do
          execute_lock_acquire(AUTOMATIC_DEPLOY_LOCK_MESSAGE)
          break
        rescue LockHeldError
          unless details_shown
            status = capture_lock_status

            say "Deploy lock is held by:", :magenta
            puts status

            unless status.include?(AUTOMATIC_DEPLOY_LOCK_MESSAGE)
              raise LockError, "Deploy lock held manually, not waiting. Run 'kamal lock help' for more information"
            end

            details_shown = true
          end

          remaining = (deadline - Time.now).to_i
          if remaining <= 0
            say "Timed out after #{timeout}s waiting for the deploy lock", :red
            raise LockError, "Timed out waiting for deploy lock"
          end

          say "Retrying in #{interval}s (#{remaining}s remaining)...", :magenta
          sleep [ interval, remaining ].min
        end
      end

      def release_lock
        say "Releasing the deploy lock...", :magenta
        execute_lock_release

        KAMAL.holding_lock = false
      end

      def raise_if_locked
        yield
      rescue LockHeldError
        say "Deploy lock already in place!", :red
        puts capture_lock_status
        raise LockError, "Deploy lock found. Run 'kamal lock help' for more information"
      end

      def execute_lock_acquire(message, lock: KAMAL.lock, hosts: KAMAL.primary_host)
        on(hosts) { execute *lock.acquire(message, KAMAL.config.version), verbosity: :debug }
      rescue SSHKit::Runner::ExecuteError => e
        raise LockHeldError if e.message =~ /cannot create directory/
        raise
      end

      def execute_lock_release(lock: KAMAL.lock, hosts: KAMAL.primary_host)
        on(hosts) { execute *lock.release, verbosity: :debug }
      rescue SSHKit::Runner::ExecuteError => e
        raise LockMissingError if e.message =~ /No such file or directory/
        raise
      end

      def capture_lock_status(lock: KAMAL.lock, hosts: KAMAL.primary_host)
        status = nil
        on(hosts) { status = capture_with_debug(*lock.status) }
        status
      rescue SSHKit::Runner::ExecuteError => e
        raise LockMissingError if e.message =~ /No such file or directory/
        raise
      end

      def on(*args, &block)
        pre_connect_if_required

        super
      end

      def pre_connect_if_required
        if !KAMAL.connected?
          run_hook "pre-connect", secrets: true unless options[:skip_hooks]
          KAMAL.connected = true
        end
      end

      def command
        @kamal_command ||= begin
          invocation_class, invocation_commands = *first_invocation
          if invocation_class == Kamal::Cli::Main
            invocation_commands[0]
          else
            Kamal::Cli::Main.subcommand_classes.find { |command, clazz| clazz == invocation_class }[0]
          end
        end
      end

      def subcommand
        @kamal_subcommand ||= begin
          invocation_class, invocation_commands = *first_invocation
          invocation_commands[0] if invocation_class != Kamal::Cli::Main
        end
      end

      def first_invocation
        instance_variable_get("@_invocations").first
      end

      def reset_invocation(cli_class)
        instance_variable_get("@_invocations")[cli_class].pop
      end

      def ensure_run_directory
        on(KAMAL.hosts) do
          execute(*KAMAL.server.ensure_run_directory)
        end
      end

      def with_env(env)
        current_env = ENV.to_h.dup
        ENV.update(env)
        yield
      ensure
        ENV.clear
        ENV.update(current_env)
      end

      def ensure_docker_installed
        run_locally do
          begin
            execute *KAMAL.builder.ensure_docker_installed
          rescue SSHKit::Command::Failed => e
            error = e.message =~ /command not found/ ?
              "Docker is not installed locally" :
              "Docker buildx plugin is not installed locally"

            raise DependencyError, error
          end
        end
      end
  end
end
