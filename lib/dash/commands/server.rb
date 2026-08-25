class Dash::Commands::Server < Dash::Commands::Base
  def remove_app_directory
    remove_directory config.app_directory
  end

  def app_directory_count
    pipe \
      [ :ls, config.apps_directory ],
      [ :wc, "-l" ]
  end

  # Lists TCP listeners on the given port, one line per listener, no header.
  def listeners_on(port)
    [ :ss, "-ltnH", :sport, "=", ":#{port}" ]
  end
end
