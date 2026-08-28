# frozen_string_literal: true

require "rails_helper"

# Every authored reference page is a hand-written Phlex class registered in Doc.
# This spec renders each one through the docs shell and asserts it comes back
# 200 with its masthead heading — so a page that fails to render (a bad component
# call, a missing method) fails the build. Unwritten registry entries (no
# view_class yet) are skipped, so this grows automatically as pages land.
RSpec.describe "Docs pages", type: :request do
  Doc.all.select(&:view_class).each do |doc|
    it "renders the #{doc.slug} page" do
      get "/docs/#{doc.slug}"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("<h1") # the doc Header masthead
      expect(response.body).to include(CGI.escapeHTML(doc.title)).or include(doc.title)
    end

    # DocsUI::Code defaults to the Ruby lexer and uses `filename:` only for the
    # title bar, so a deploy.yml example without `lexer: :yaml` is silently
    # highlighted as Ruby (and its .md twin gets a ```ruby fence). Guard both the
    # symptom (Rouge Error tokens) and the cause (a YAML-named block lexed as
    # something else) until docs-kit infers the lexer from the filename.
    it "highlights every code block on #{doc.slug} with the right lexer" do
      get "/docs/#{doc.slug}"
      html = Nokogiri::HTML(response.body)

      expect(html.css(".code-highlight .err")).to be_empty, "#{doc.slug}: Rouge Error tokens in a code block"

      html.css(".code-highlight").each do |block|
        filename = block.previous_element&.at_css("span")&.text.to_s
        next unless filename.match?(/\.ya?ml\z/)

        expect(block["data-md-lang"]).to eq("yaml"), "#{doc.slug}: #{filename} block is lexed as #{block["data-md-lang"]}"
      end
    end

    it "serves a Markdown twin for #{doc.slug}" do
      get "/docs/#{doc.slug}.md"
      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("text/markdown")
    end
  end

  it "404s an unknown doc slug" do
    get "/docs/does-not-exist"
    expect(response).to have_http_status(:not_found)
  end

  it "renders the landing page" do
    get "/"
    expect(response).to have_http_status(:ok)
  end
end
