# frozen_string_literal: true

# Getting the dash executable installed — standalone or Gemfile-managed.
class Views::Docs::Pages::Installation < DocsUI::Page
  title "Installation"
  eyebrow "Getting started"

  def lead = "Install the gem, run dash init, and you are ready to configure a deploy."

  def content
    requirements
    install_gem
    initialize_project
    verify
  end

  private

  def requirements
    DocsUI::Section("Requirements") do
      DocsUI::Table(
        [ "Where", "Requirement" ],
        [
          [ "Your machine", [ :md, "Ruby >= 3.2, Docker (to build images), SSH access to your servers" ] ],
          [ "Your servers", [ :md, "Any Linux host you can SSH into — `dash server bootstrap` installs Docker via `curl` if it is missing" ] ],
          [ "A registry", [ :md, "Docker Hub, ghcr.io, or any private registry — dash pushes your image there and the servers pull it" ] ]
        ]
      )
    end
  end

  def install_gem
    DocsUI::Section("Install the gem") do
      md <<~'MD'
        Standalone:
      MD
      DocsUI::Code(<<~SHELL, lexer: :shell)
        gem install dash
      SHELL
      md <<~'MD'
        Or Gemfile-managed, so every collaborator gets the same pinned version:
      MD
      DocsUI::Code(<<~SHELL, lexer: :shell)
        bundle add dash
        bundle binstubs dash
      SHELL
      DocsUI::Callout(:note) do
        plain "The gem is named "
        code { "dash" }
        plain " and the executable is "
        code { "dash" }
        plain ". With binstubs, run it as "
        code { "bin/dash" }
        plain "."
      end
    end
  end

  def initialize_project
    DocsUI::Section("Initialize the project") do
      md <<~'MD'
        From your app's root:
      MD
      DocsUI::Code(<<~SHELL, lexer: :shell)
        dash init
      SHELL
      md <<~'MD'
        This writes two stubs:

        - `config/deploy.yml` — the deployment configuration; every key is
          documented in the [Configuration](/docs/configuration) reference.
        - `.kamal/secrets` — where registry passwords and other secrets are
          read from (dotenv format, command substitution supported).
      MD
    end
  end

  def verify
    DocsUI::Section("Verify") do
      DocsUI::Code(<<~SHELL, lexer: :shell)
        dash version         # the installed gem version
        dash docs            # the full configuration reference, in your terminal
        dash doctor          # once configured: diagnose deploy readiness
      SHELL
      md <<~'MD'
        Then head to the [Quick start](/docs/quick-start) for your first deploy.
      MD
    end
  end
end
