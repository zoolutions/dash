# frozen_string_literal: true

require "rails_helper"

# The Configuration pages are generated from the gem's commented-YAML docs
# (lib/dash/configuration/docs/*.yml — the same files `dash docs` prints).
# This spec keeps the Doc registry honest against that directory, in both
# directions, so the reference can't silently drift from the gem:
#
#   1. Every doc YAML must have a registered Configuration page.
#   2. Every generated (ConfigPage) Configuration page must point at a real doc YAML.
#   3. The parser must extract a title and content from every file.
RSpec.describe "Config docs drift", type: :model do
  let(:yaml_slugs) { ConfigDoc.slugs.sort }
  # Hand-written pages may sit in the Configuration group (Secrets adapters);
  # only ConfigPage subclasses are bound to a YAML.
  let(:config_pages) { Doc.grouped.fetch("Configuration").select { |page| page.view_class < Views::Docs::Pages::ConfigPage } }
  let(:page_slugs) { config_pages.map(&:slug).sort }

  it "registers a Configuration page for every gem doc YAML" do
    missing = yaml_slugs - page_slugs
    expect(missing).to be_empty, <<~MSG
      New doc YAMLs under lib/dash/configuration/docs have no page: #{missing.inspect}
      Add a `page` line to the Configuration group in app/models/doc.rb and a
      Views::Docs::Pages::Config::* class binding it with `config_doc`.
    MSG
  end

  it "has a gem doc YAML for every Configuration page" do
    orphaned = page_slugs - yaml_slugs
    expect(orphaned).to be_empty,
                        "Configuration pages without a doc YAML: #{orphaned.inspect}"
  end

  it "binds every Configuration page view to its own YAML" do
    config_pages.each do |page|
      expect(page.view_class.config_doc).to eq(page.slug),
                                            "#{page.view_class} renders #{page.view_class.config_doc.inspect}, expected #{page.slug.inspect}"
    end
  end

  it "parses a title and content out of every doc YAML" do
    ConfigDoc.all.each do |doc|
      expect(doc.title).to be_present, "#{doc.slug}.yml produced no title"
      expect(doc.preamble.any? || doc.sections.any?).to be(true),
                                                        "#{doc.slug}.yml produced no content"
    end
  end

  # The YAML examples in those files sit under their parent keys (`accessories:
  # mysql:` → 4/6-space columns). The parser must strip that common indent before
  # the text reaches DocsUI::Code: DocsUI::Code strips only the head of the whole
  # string, so an un-dedented block renders line 1 flush-left and the rest
  # staggered, and Rouge's YAML lexer then flags the malformed shape with Error
  # tokens (rendered as maroon squares on dark themes).
  describe "YAML examples" do
    def yaml_nodes(doc) = (doc.preamble + doc.sections.flat_map(&:nodes)).select { |n| n.kind == :yaml }

    it "dedents every YAML example to column zero" do
      ConfigDoc.all.each do |doc|
        yaml_nodes(doc).each do |node|
          lines = node.text.lines.reject(&:blank?)
          expect(lines.first).not_to start_with(" "), "#{doc.slug}.yml: block starts indented:\n#{node.text}"
          expect(lines.map { |l| l[/\A */].size }.min).to eq(0), "#{doc.slug}.yml: block not dedented:\n#{node.text}"
        end
      end
    end

    it "keeps relative indentation when dedenting" do
      node = yaml_nodes(ConfigDoc.for("accessory")).find { |n| n.text.include?("host: mysql-db1") }
      expect(node.text).to start_with("host: mysql-db1\nhosts:\n  - mysql-db1")
    end

    # Lexes `text.strip`, exactly what DocsUI::Code hands to Rouge.
    it "lexes every YAML example without Rouge Error tokens" do
      lexer = Rouge::Lexer.find("yaml")
      ConfigDoc.all.each do |doc|
        yaml_nodes(doc).each do |node|
          errors = lexer.lex(node.text.strip).select { |tok, _| tok.qualname == "Error" }.map(&:last)
          expect(errors).to be_empty, "#{doc.slug}.yml: Rouge Error tokens #{errors.inspect} in:\n#{node.text}"
        end
      end
    end
  end
end
