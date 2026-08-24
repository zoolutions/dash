class Dash::Cli::Registry < Dash::Cli::Base
  desc "setup", "Setup local registry or log in to remote registry locally and remotely"
  option :skip_local, aliases: "-L", type: :boolean, default: false, desc: "Skip local login"
  option :skip_remote, aliases: "-R", type: :boolean, default: false, desc: "Skip remote login"
  def setup
    ensure_docker_installed unless options[:skip_local]

    if DASH.registry.local?
      run_locally    { execute *DASH.registry.setup } unless options[:skip_local]
    else
      run_locally    { execute *DASH.registry.login } unless options[:skip_local]
      on(DASH.hosts) { execute *DASH.registry.login } unless options[:skip_remote]
    end
  end

  desc "remove", "Remove local registry or log out of remote registry locally and remotely"
  option :skip_local, aliases: "-L", type: :boolean, default: false, desc: "Skip local login"
  option :skip_remote, aliases: "-R", type: :boolean, default: false, desc: "Skip remote login"
  def remove
    if DASH.registry.local?
      run_locally    { execute *DASH.registry.remove, raise_on_non_zero_exit: false } unless options[:skip_local]
    else
      run_locally    { execute *DASH.registry.logout } unless options[:skip_local]
      on(DASH.hosts) { execute *DASH.registry.logout } unless options[:skip_remote]
    end
  end

  desc "login", "Log in to remote registry locally and remotely"
  option :skip_local, aliases: "-L", type: :boolean, default: false, desc: "Skip local login"
  option :skip_remote, aliases: "-R", type: :boolean, default: false, desc: "Skip remote login"
  def login
    if DASH.registry.local?
      raise "Cannot use login command with a local registry. Use `dash registry setup` instead."
    end

    setup
  end

  desc "logout", "Log out of remote registry locally and remotely"
  option :skip_local, aliases: "-L", type: :boolean, default: false, desc: "Skip local login"
  option :skip_remote, aliases: "-R", type: :boolean, default: false, desc: "Skip remote login"
  def logout
    if DASH.registry.local?
      raise "Cannot use logout command with a local registry. Use `dash registry remove` instead."
    end

    remove
  end
end
