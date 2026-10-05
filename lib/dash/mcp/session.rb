# What one `dash mcp` process knows between questions: where deploy.yml is, the scope the
# operator started it with, whether logs are allowed, and the redactor.
#
# Every question reads deploy.yml afresh (an edit shows up without a restart) through
# Commander#reconfigure, which keeps `connected`: the pre-connect hook ran once at boot
# and does not run again. The operator's --hosts/--roles are a ceiling: a call can narrow
# inside it, never widen past it.
class Dash::Mcp::Session
  attr_reader :redactor

  def initialize(config_file:, redactor:, destination: nil, version: nil, hosts: nil, roles: nil, allow_logs: false)
    @config = { config_file: config_file, destination: destination, version: version }
    @redactor = redactor
    @hosts, @roles = hosts.presence, roles.presence
    @allow_logs = allow_logs
    @mutex = Mutex.new
  end

  def allow_logs?
    @allow_logs
  end

  def answer(hosts: nil, roles: nil)
    @mutex.synchronize do
      DASH.reconfigure(**@config)
      DASH.specific_hosts = @hosts
      DASH.specific_roles = @roles
      narrow(hosts: Array(hosts).presence, roles: Array(roles).presence)

      yield
    end
  end

  private
    def narrow(hosts:, roles:)
      if roles
        names = Dash::Utils.filter_specific_items(roles, DASH.roles).map(&:name)
        raise ArgumentError, "No roles match #{roles.join(",")} within this server's scope (#{DASH.roles.map(&:name).join(",")})" if names.empty?

        DASH.specific_roles = names
      end

      if hosts
        names = Dash::Utils.filter_specific_items(hosts, DASH.hosts)
        raise ArgumentError, "No hosts match #{hosts.join(",")} within this server's scope (#{DASH.hosts.join(",")})" if names.empty?

        DASH.specific_hosts = names
      end
    end
end
