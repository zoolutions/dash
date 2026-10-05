# Per app host, every container of this service and destination: role, replica slot,
# version, state and health. One `docker ps` per host, whatever the roles and slots.
class Dash::Diagnostics::Containers < Dash::Diagnostics::Base
  def initialize(hosts: DASH.app_hosts)
    @hosts = hosts
  end

  private
    def snapshot
      { hosts: per_host(@hosts) { |backend, _host| { containers: Dash::Diagnostics::DockerPs.containers(backend.capture_with_info(*DASH.app.list_containers_json)) } } }
    end
end
