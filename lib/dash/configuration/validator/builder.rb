class Dash::Configuration::Validator::Builder < Dash::Configuration::Validator
  def validate!
    super

    if config["cache"] && config["cache"]["type"]
      error "Invalid cache type: #{config["cache"]["type"]}" unless [ "gha", "registry" ].include?(config["cache"]["type"])
    end

    error "Builder arch not set" unless config["arch"].present?

    error "buildpacks only support building for one arch" if config["pack"] && config["arch"].is_a?(Array) && config["arch"].size > 1

    error "Cannot disable local builds, no remote is set" if config["local"] == false && config["remote"].blank?

    validate_output_level!(config["output"]) if config.key?("output")
  end

  private
    def validate_output_level!(level)
      # The type check lets a boolean or a number through as a string; this rejects it.
      return if Dash::Configuration::HOOKS_OUTPUT_LEVELS.include?(level.to_s.to_sym)

      with_context("output") do
        error "Invalid output '#{level}', must be one of: #{Dash::Configuration::HOOKS_OUTPUT_LEVELS.join(', ')}"
      end
    end
end
