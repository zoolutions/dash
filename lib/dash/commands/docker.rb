class Dash::Commands::Docker < Dash::Commands::Base
  # Install Docker using the https://github.com/docker/docker-install convenience script.
  def install
    pipe get_docker, :sh
  end

  # Checks the Docker client version. Fails if Docker is not installed.
  def installed?
    docker "-v"
  end

  # Checks the Docker server version. Fails if Docker is not running.
  def running?
    docker :version
  end

  # Do we have superuser access to install Docker and start system services?
  def superuser?
    [ '[ "${EUID:-$(id -u)}" -eq 0 ] || sudo -nl usermod >/dev/null' ]
  end

  def root?
    [ '[ "${EUID:-$(id -u)}" -eq 0 ]' ]
  end

  def in_docker_group?
    [ 'id -nG "${USER:-$(id -un)}" | grep -qw docker' ]
  end

  def add_to_docker_group
    [ 'sudo -n usermod -aG docker "${USER:-$(id -un)}"' ]
  end

  def refresh_session
    [ "kill -HUP $PPID" ]
  end

  # Checks that an image's manifest can be fetched from its registry. Fails if it's missing or we're unauthorized.
  def manifest_available?(image)
    docker :manifest, :inspect, image
  end

  def create_network
    docker :network, :create, Dash::Configuration::Proxy::NETWORK
  end

  # Stage 3c: docker cannot rename a network, so `dash` is created alongside
  # `kamal` and everything still on the old one is joined to the new one.
  #
  # App containers would be replaced by the next deploy anyway; accessories are
  # not, and that is the whole point — without this a renamed proxy cannot
  # reach `db` or `redis`. Connecting a container that is already attached
  # fails, so each connect tolerates its own failure rather than aborting the
  # sweep. The old network is never removed; that is documented manual cleanup
  # and stage 3d's code change.
  def connect_legacy_network_containers
    any \
      combine(
        legacy_network_exists,
        pipe(legacy_network_container_names, connect_each_to_network)
      ),
      [ :true ]
  end

  private
    def legacy_network_exists
      docker :network, :inspect, Dash::Configuration::Proxy::LEGACY_NETWORK, ">", "/dev/null", "2>&1"
    end

    def legacy_network_container_names
      docker :network, :inspect, Dash::Configuration::Proxy::LEGACY_NETWORK,
        "--format", "'{{range .Containers}}{{.Name}}{{\"\\n\"}}{{end}}'"
    end

    # Already-attached containers make `network connect` fail; tolerate each
    # one's failure rather than letting it abort the sweep.
    def connect_each_to_network
      [ :xargs, "-r", "-I{}", "sh", "-c",
        "'docker network connect #{Dash::Configuration::Proxy::NETWORK} {} 2>/dev/null || true'" ]
    end

    def get_docker
      shell \
        any \
          [ :curl, "-fsSL", "https://get.docker.com" ],
          [ :wget, "-O -", "https://get.docker.com" ],
          [ :echo, "\"exit 1\"" ]
    end
end
