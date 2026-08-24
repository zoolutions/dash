# frozen_string_literal: true

require "rails_helper"

# The Configuration pages are generated from the gem's commented-YAML docs
# (lib/kamal/configuration/docs/*.yml — the same files `dash docs` prints).
# This spec keeps the Doc registry honest against that directory, in both
# directions, so the reference can't silently drift from the gem:
#
#   1. Every doc YAML must have a registered Configuration page.
#   2. Every Configuration page must point at a real doc YAML.
#   3. The parser must extract a title and content from every file.
RSpec.describe "Config docs drift", type: :model do
  let(:yaml_slugs) { ConfigDoc.slugs.sort }
  let(:config_pages) { Doc.grouped.fetch("Configuration") }
  let(:page_slugs) { config_pages.map(&:slug).sort }

  it "registers a Configuration page for every gem doc YAML" do
    missing = yaml_slugs - page_slugs
    expect(missing).to be_empty, <<~MSG
      New doc YAMLs under lib/kamal/configuration/docs have no page: #{missing.inspect}
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
end
