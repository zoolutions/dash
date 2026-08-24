require "active_support/duration"
require "active_support/core_ext/numeric/time"

class Dash::Commands::Prune < Dash::Commands::Base
  def dangling_images
    docker :image, :prune, "--force", "--filter", "label=service=#{config.service}"
  end

  def tagged_images
    pipe \
      docker(:image, :ls, *service_filter, "--format", "'{{.ID}} {{.Repository}}:{{.Tag}}'"),
      grep("-v -w \"#{active_image_list}\""),
      "while read image tag; do docker rmi $tag; done"
  end

  # Scoped to one role so a busy sibling role cannot push another role's newest
  # container past the retain window. That matters beyond disk hygiene: a
  # container kamal-proxy has put to sleep is `exited`, so it is a removal
  # candidate, and once it is gone every wake 404s. With `retain >= 1` a role's
  # newest container always survives, and the slept one is always the newest —
  # sleeping happens to the current release.
  def app_containers(retain:, role:)
    pipe \
      docker(:ps, "-q", "-a", *service_filter, *destination_filter, *role_filter(role), *stopped_containers_filters),
      "tail -n +#{retain + 1}",
      "while read container_id; do docker rm $container_id; done"
  end

  private
    def stopped_containers_filters
      [ "created", "exited", "dead" ].flat_map { |status| [ "--filter", "status=#{status}" ] }
    end

    def active_image_list
      # Pull the images that are used by any containers
      # Append repo:latest - to avoid deleting the latest tag
      # Append repo:<none> - to avoid deleting dangling images that are in use. Unused dangling images are deleted separately
      "$(docker container ls -a --format '{{.Image}}\\|' --filter label=service=#{config.service} | tr -d '\\n')#{config.latest_image}\\|#{config.repository}:<none>"
    end

    def service_filter
      [ "--filter", "label=service=#{config.service}" ]
    end

    def destination_filter
      [ "--filter", "label=destination=#{config.destination}" ]
    end

    def role_filter(role)
      [ "--filter", "label=role=#{role}" ]
    end
end
