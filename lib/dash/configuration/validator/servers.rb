class Dash::Configuration::Validator::Servers < Dash::Configuration::Validator
  def validate!
    validate_type! config, Array, Hash, NilClass

    validate_servers! config if config.is_a?(Array)
  end
end
