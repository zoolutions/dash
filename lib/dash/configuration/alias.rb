class Dash::Configuration::Alias
  include Dash::Configuration::Validation

  attr_reader :name, :command

  def initialize(name, config:)
    @name, @command = name.inquiry, config.raw_config["aliases"][name]

    validate! \
      command,
      example: validation_yml["aliases"]["uname"],
      context: "aliases/#{name}",
      with: Dash::Configuration::Validator::Alias
  end
end
