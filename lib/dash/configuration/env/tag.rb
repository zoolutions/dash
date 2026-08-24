class Dash::Configuration::Env::Tag
  attr_reader :name, :config, :secrets

  def initialize(name, config:, secrets:)
    @name = name
    @config = config
    @secrets = secrets
  end

  def env
    Dash::Configuration::Env.new(config: config, secrets: secrets)
  end
end
