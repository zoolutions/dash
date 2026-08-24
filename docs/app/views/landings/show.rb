# frozen_string_literal: true

module Views
  module Landings
    # The home page. Renders inside DocsUI::Shell (the full document + drawer
    # shell): a hero with the one-line install, a feature grid, and a grouped
    # index of the authored docs. Kept to roughly one screen — the docs are the
    # product.
    class Show < Phlex::HTML
      include Phlex::Rails::Helpers::Routes

      FEATURES = [
        [ "server", "Your servers, zero downtime",
         "Bare metal or cloud VMs — dash builds, pushes, and switches traffic " \
         "between containers over plain SSH + Docker. No control plane, no agents." ],
        [ "network", "Proxy load balancing",
         "One dash-proxy fronts the whole fleet — auto-activated for multi-host " \
         "roles, shareable between apps, with per-host proxies for gapless deploys." ],
        [ "shield-check", "SAN batching & wildcard certs",
         "Batch domains onto shared SAN certificates, issue wildcards via DNS-01, " \
         "and learn TLS hostnames from your app at runtime." ],
        [ "database-zap", "Response caching",
         "An RFC 9111 shared cache at the proxy — per-service policy, memory or " \
         "shared Redis storage, administered with dash proxy cache." ],
        [ "gauge", "Traffic shaping",
         "Rate limits, IP allow/deny lists, per-path deadlines, read routing, " \
         "session affinity, and scale to zero — enforced at the edge." ],
        [ "stethoscope", "Readiness gates",
         "dash doctor diagnoses servers, registry, proxy, ports, DNS, and " \
         "certificates before you commit to a deploy." ]
      ].freeze

      def view_template
        DocsUI::Shell(
          title: nil,
          description: DocsKit.configuration.tagline
        ) do
          hero
          feature_grid
          docs_section
        end
      end

      private

      def hero
        section(class: "not-prose mb-14") do
          div(class: "flex items-center gap-3 mb-6") do
            brand_mark
            span(class: "text-sm font-semibold tracking-wide opacity-70") { "dash" }
          end
          h1(class: "text-4xl sm:text-5xl font-extrabold tracking-tight mb-4 leading-tight") do
            plain "Deploy web apps "
            span(class: "bg-gradient-to-r from-primary to-accent bg-clip-text text-transparent") { "anywhere" }
          end
          p(class: "text-lg sm:text-xl opacity-80 max-w-2xl mb-7") do
            plain "From bare metal to cloud VMs, with zero downtime. dash uses "
            a(href: "https://github.com/zoolutions/dash-proxy", class: "link", target: "_blank", rel: "noopener") { "dash-proxy" }
            plain " to switch requests between containers, balance load across hosts, and manage certificates — "
            strong { "your servers, one config file." }
          end
          div(class: "not-prose mb-8 max-w-xl") do
            DocsUI::Code(<<~SHELL, lexer: :shell)
              gem install dash
              dash init && dash setup
            SHELL
          end
          div(class: "flex flex-wrap gap-3") do
            a(href: doc_path("quick-start"), class: "btn btn-primary") { "Get started" }
            a(href: doc_path("from-kamal"), class: "btn btn-ghost") { "Coming from kamal?" }
            a(href: "https://github.com/zoolutions/dash",
              class: "btn btn-ghost", target: "_blank", rel: "noopener") { "GitHub ↗" }
          end
        end
      end

      def brand_mark
        div(class: "w-9 h-9 rounded-lg bg-base-200 grid place-items-center") do
          div(class: "w-5 h-5 rotate-45 rounded-sm bg-gradient-to-br from-primary to-accent")
        end
      end

      def feature_grid
        section(class: "not-prose mb-16") do
          div(class: "grid gap-4 sm:grid-cols-2") do
            FEATURES.each { feature_card(it) }
          end
        end
      end

      def feature_card((icon, title, body))
        div(class: "card bg-base-200/60 border border-base-300 p-5") do
          div(class: "flex items-start gap-3") do
            div(class: "text-primary mt-0.5") { DocsUI::Icon(icon) }
            div do
              h3(class: "font-semibold mb-1") { title }
              p(class: "text-sm opacity-70") { body }
            end
          end
        end
      end

      def docs_section
        section(class: "not-prose") do
          h2(class: "text-sm uppercase tracking-wide opacity-60 mb-4") { "Documentation" }
          Doc.grouped.each do |group, docs|
            written = docs.select(&:view_class)
            next if written.empty?

            h3(class: "text-xs font-semibold uppercase tracking-wider opacity-40 mt-5 mb-2") { group }
            div(class: "grid gap-2 sm:grid-cols-2") do
              written.each { doc_link(it) }
            end
          end
        end
      end

      def doc_link(doc)
        a(href: doc_path(doc.slug),
          class: "link link-hover text-sm py-1 flex items-center gap-2") do
          span(class: "text-primary/50") { "›" }
          plain doc.title
        end
      end
    end
  end
end
