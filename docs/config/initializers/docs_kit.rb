# frozen_string_literal: true

# docs-kit synced: v1.0.8

# docs-kit configuration — everything that makes this site look like "dash"
# rather than any other docs site. The shared chrome (Shell/Sidebar/ThemeSwitcher/
# Code/Page) comes from the gem; only this config differs per site. The `themes`
# MUST match the @plugin "daisyui" { themes: ... } block in
# app/assets/stylesheets/application.tailwind.css, or the switcher offers a theme
# the compiled CSS never generated.
Rails.application.config.to_prepare do
  DocsKit.configure do |c|
    c.brand        = "dash"
    c.title_suffix = "dash"

    # The one-line summary agents read first in /llms.txt (the llmstxt.org
    # blockquote under the H1).
    c.tagline = "Deploy web apps anywhere with zero downtime — containers, " \
                "SSH, and dash-proxy. Load balancing, SAN certificate batching, " \
                "wildcard certs, response caching, and traffic shaping upstream " \
                "kamal doesn't have. Existing kamal deployments upgrade in place."

    c.themes = %w[dark light synthwave retro cyberpunk dracula night nord sunset]

    # The version badge in the sidebar header tracks the documented gem. A lambda
    # (not a String) so it re-reads Dash::VERSION on every reload — the dash
    # path-gem is required as "dash/version" (Gemfile), so only the constant is
    # loaded; the CLI never boots inside the docs app.
    c.version_badge = -> { "v#{Dash::VERSION}" }

    # Code blocks: a light base with a dark override, so the highlight stays
    # readable when the switcher lands on a dark daisyUI theme. CSS-only scoping
    # ([data-theme=X]) — no JS, no flash.
    c.code_theme      = "Rouge::Themes::Github"  # light themes
    c.code_theme_dark = "Rouge::Themes::Monokai" # dark themes

    # The shipped themes that are dark, so code_theme_dark scopes to them. Set
    # explicitly because docs-kit's DEFAULT_DARK_THEMES omits `nord`, which
    # otherwise fell back to the light Github palette. Keep in sync with `themes`.
    # Monokai's own container background is overridden per dark theme in
    # application.tailwind.css so the block matches the page palette.
    c.dark_themes = %w[dark synthwave dracula night nord sunset]

    # A link to the source repo in the topbar, rendered with the shipped GitHub
    # brand mark.
    c.topbar_links = [
      { href: "https://github.com/zoolutions/dash", label: "GitHub", icon: :github }
    ]

    # SEO + social sharing. docs-kit emits the full <head> (description, Open
    # Graph, Twitter Card, canonical, favicon, theme-color) from these knobs.
    # og_image resolves through THIS site's asset pipeline (app/assets/images/) to
    # the digested /assets URL — regenerate the card with `bin/rails docs_kit:og`.
    c.seo.description  = "dash deploys web apps in containers to any server " \
                         "running Docker with zero downtime — proxy load " \
                         "balancing, SAN certificate batching, wildcard certs, " \
                         "response caching, and traffic shaping. A clean-break " \
                         "kamal fork; existing deployments upgrade in place."
    c.seo.site_url     = "https://dash.zoolutions.llc"
    c.seo.og_image     = "og/og.png"
    c.seo.og_type      = "website"
    c.seo.twitter_card = "summary_large_image"
    c.seo.twitter_site = "@mhenrixon"
    c.seo.locale       = "en_US"
    c.seo.theme_color  = "#1d232a" # daisyUI dark base-100 (themes.first)
    # favicon href is used verbatim (not through the asset pipeline), so it's a
    # public/ path served at a stable root URL — see public/favicon.svg.
    c.seo.favicon      = "/favicon.svg"

    # The sidebar nav derives from the registry — one heading → one registry.
    # Each registry's authored pages become NavItems automatically (an unwritten
    # page is skipped, so no dead links); the page `group:` values render as the
    # collapsible sub-groups. This also feeds the AI surfaces (/llms.txt,
    # /llms-full.txt, search, MCP) with zero extra code.
    c.nav_registries = { "Docs" => Doc }
  end
end
