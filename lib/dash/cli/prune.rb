class Dash::Cli::Prune < Dash::Cli::Base
  desc "all", "Prune unused images and stopped containers"
  def all
    modify(lock: true, server_lock: true) do
      containers
      images
    end
  end

  desc "images", "Prune unused images"
  def images
    modify(lock: true, server_lock: true) do
      on(DASH.hosts) do
        execute *DASH.auditor.record("Pruned images"), verbosity: :debug
        execute *DASH.prune.dangling_images
        execute *DASH.prune.tagged_images
      end
    end
  end

  desc "containers", "Prune all stopped containers, except the last n per role (default 5)"
  option :retain, type: :numeric, default: nil, desc: "Number of containers to retain per role"
  def containers
    retain = options.fetch(:retain, DASH.config.retain_containers)
    raise "retain must be at least 1" if retain < 1

    modify(lock: true, server_lock: true) do
      on(DASH.hosts) do |host|
        execute *DASH.auditor.record("Pruned containers"), verbosity: :debug

        DASH.roles_on(host).each do |role|
          execute *DASH.prune.app_containers(retain: retain, role: role)
        end
      end
    end
  end
end
