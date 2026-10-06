module Dash::Autoscale::Provider
  def self.for(autoscale)
    case autoscale.provider_name
    when "upcloud" then Dash::Autoscale::Provider::Upcloud.new(username: -> { autoscale.upcloud_username }, password: -> { autoscale.upcloud_password })
    when "exec" then Dash::Autoscale::Provider::Exec.new(scripts: ->(action) { autoscale.exec_script(action) })
    else raise Dash::Autoscale::ProviderError, "no autoscale provider configured"
    end
  end
end
