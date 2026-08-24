# frozen_string_literal: true

# Shared superclass for the generated Configuration pages. A subclass declares
# which commented-YAML doc it renders (`config_doc "proxy"`) and a lead; the
# parsed content comes from ConfigDoc, so the page can never drift from what
# `dash docs <section>` prints.
class Views::Docs::Pages::ConfigPage < DocsUI::Page
  class << self
    # `config_doc "proxy"` binds the page to lib/dash/configuration/docs/proxy.yml
    # and derives title + eyebrow (both still overridable with the standard
    # Page DSL, called before config_doc).
    def config_doc(slug = nil)
      if slug
        @config_slug = slug
        # Page's title/eyebrow DSL stores per-class ivars with no inheritance,
        # so seed them here rather than on this superclass.
        @title ||= ConfigDoc.for(slug).title
        @eyebrow ||= "Configuration"
      end
      @config_slug
    end
  end

  def content
    render_nodes doc.preamble
    doc.sections.each do |section|
      DocsUI::Section(section.title) { render_nodes(section.nodes) }
    end
    provenance
  end

  private

  def doc = ConfigDoc.for(self.class.config_doc)

  def render_nodes(nodes)
    nodes.each do |node|
      case node.kind
      when :heading then md("### #{node.text}")
      when :prose   then md(node.text)
      when :yaml    then DocsUI::Code(node.text, lexer: :yaml)
      end
    end
  end

  def provenance
    DocsUI::Callout(:note) do
      plain "Generated from the gem's "
      code { "lib/dash/configuration/docs/#{doc.slug}.yml" }
      plain " — the same reference "
      code { "dash docs #{doc.slug unless doc.slug == 'configuration'}".strip }
      plain " prints in your terminal, so this page always matches your installed version."
    end
  end
end
