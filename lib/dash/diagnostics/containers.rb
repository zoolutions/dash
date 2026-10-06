# Per app host, every container of this service and destination: role, replica slot,
# version, state and health. One `docker ps` per host, whatever the roles and slots. Then
# each accessory's container on its own hosts.
class Dash::Diagnostics::Containers < Dash::Diagnostics::Base
  # `accessories: []` for the app alone, `hosts: []` for accessories alone.
  def initialize(hosts: DASH.app_hosts, accessories: DASH.config.accessories)
    @hosts = hosts
    @accessories = accessories
  end

  private
    def snapshot
      { hosts: per_host(@hosts) { |backend, _host| { containers: Dash::Diagnostics::DockerPs.containers(backend.capture_with_info(*DASH.app.list_containers_json)) } },
        accessories: per_accessory(@accessories) { |accessory, backend, _host| { containers: accessory_containers(accessory, backend) } } }
    end

    def accessory_containers(accessory, backend)
      Dash::Diagnostics::DockerPs.containers(backend.capture_with_info(*DASH.accessory(accessory.name).list_containers_json), accessory: accessory.name)
    end
end
