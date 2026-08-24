class Dash::Cli::Alias::Command < Thor::DynamicCommand
  def run(instance, args = [])
    if (command = DASH.resolve_alias(name))
      DASH.reset
      Dash::Cli::Main.start(Shellwords.split(command) + ARGV[1..-1])
    else
      super
    end
  end
end
