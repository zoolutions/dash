# Powers a pool member off through the provider and waits for it to be stopped, then
# deletes it when the role creates its members. The provider's soft stop gets the role's
# stop budget plus room for the operating system to shut down.
class Dash::Cli::Scale::PowerOff
  SHUTDOWN_ALLOWANCE = 30
  DEFAULT_STOP_TIMEOUT = 30

  def initialize(role, member, provider)
    @role = role
    @member = member
    @provider = provider
  end

  def run(destroy:)
    timeout = (@role.stop_timeout || DEFAULT_STOP_TIMEOUT) + SHUTDOWN_ALLOWANCE

    # A member a failed join left stopped refuses a second stop (UpCloud answers
    # SERVER_STATE_ILLEGAL), which would skip the destroy.
    unless @provider.state(@member) == "stopped"
      @provider.stop(@member, timeout: timeout)
      @provider.wait_until(@member, state: "stopped", timeout: timeout + SHUTDOWN_ALLOWANCE)
    end

    @provider.destroy(@member) if destroy
  end
end
