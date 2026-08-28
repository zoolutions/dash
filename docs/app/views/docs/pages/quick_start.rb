# frozen_string_literal: true

# The first deploy, end to end: init, configure, setup, deploy.
class Views::Docs::Pages::QuickStart < DocsUI::Page
  title "Quick start"
  eyebrow "Getting started"

  def lead = "From a containerizable app to a live deploy on your own server."

  def content
    configure
    secrets
    first_deploy
    every_deploy_after
    useful_commands
  end

  private

  def configure
    DocsUI::Section("Configure the deploy") do
      md <<~'MD'
        After [installing](/docs/installation) and running `dash init`, describe
        your deployment in `config/deploy.yml`. The minimum is a service name,
        an image, servers, and a registry:
      MD
      DocsUI::Code(<<~YAML, filename: "config/deploy.yml", lexer: :yaml)
        # The name of your application, used to identify containers on the servers.
        service: myapp

        # The image name; the registry prefix decides where it is pushed.
        image: my-user/myapp

        # The hosts to deploy to. A flat list implies a single `web` role.
        servers:
          - 192.168.0.1

        # Let the proxy terminate SSL for your domain (needs DNS pointed at the
        # server and port 443 open).
        proxy:
          ssl: true
          host: app.example.com

        # The registry to push to (Docker Hub unless `server` says otherwise).
        registry:
          username: my-user
          password:
            - DASH_REGISTRY_PASSWORD

        # The architecture to build for.
        builder:
          arch: amd64
      YAML
      md <<~'MD'
        Your app needs a `Dockerfile` that boots it on port 80 (or set
        `proxy: app_port:`), and should answer `GET /up` with a 200 once healthy
        — that is the default healthcheck the proxy gates traffic on.
      MD
    end
  end

  def secrets
    DocsUI::Section("Provide the registry password") do
      md <<~'MD'
        Secrets are read from `.dash/secrets` — dotenv format, with command
        substitution for password managers:
      MD
      DocsUI::Code(<<~SHELL, filename: ".dash/secrets", lexer: :shell)
        DASH_REGISTRY_PASSWORD=$DASH_REGISTRY_PASSWORD
      SHELL
      md <<~'MD'
        See the [Environment](/docs/env) reference for secret env vars and
        [Secrets adapters](/docs/secrets) for the vaults `dash secrets fetch`
        supports.
      MD
    end
  end

  def first_deploy
    DocsUI::Section("First deploy") do
      DocsUI::Code(<<~SHELL, lexer: :shell)
        dash setup
      SHELL
      md <<~'MD'
        `setup` is the bootstrap-everything path: it installs Docker on the
        servers if needed, logs in to the registry, boots the proxy and any
        [accessories](/docs/accessory), then builds, pushes, and deploys the
        app. When it finishes, your app is serving traffic.

        Not sure the servers are ready? `dash doctor` diagnoses servers,
        registry, proxy, ports, DNS, and certificates before you commit to a
        deploy.
      MD
    end
  end

  def every_deploy_after
    DocsUI::Section("Every deploy after") do
      DocsUI::Code(<<~SHELL, lexer: :shell)
        dash deploy
      SHELL
      md <<~'MD'
        Builds the image from the current git HEAD, pushes, pulls on the
        servers, boots the new containers, waits for health, and switches
        traffic — zero downtime. Roll back to a previous version with:
      MD
      DocsUI::Code(<<~SHELL, lexer: :shell)
        dash rollback [VERSION]
      SHELL
    end
  end

  def useful_commands
    DocsUI::Section("Useful from day one") do
      DocsUI::Code(<<~SHELL, lexer: :shell)
        dash app logs -f          # follow app logs across servers
        dash app exec "bin/rails console"   # run a command in the app container
        dash details              # what is running where
        dash audit                # who deployed what, when
      SHELL
      md <<~'MD'
        The full surface is on the [Commands](/docs/commands) page, and
        [Aliases](/docs/alias) shorten the ones you use daily.
      MD
    end
  end
end
