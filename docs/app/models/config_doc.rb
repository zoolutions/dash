# frozen_string_literal: true

# Parses the gem's commented-YAML configuration docs — the same files `dash docs`
# prints (lib/dash/configuration/docs/*.yml) — into renderable nodes, so the
# Configuration pages are generated from the single source of truth and can
# never drift from what the CLI shows.
#
# The format, by convention in those files:
#
#   - `# ====` divider pairs wrap a big-section title (proxy.yml only) → :h2.
#   - A comment block whose first line is short, unpunctuated, and followed by a
#     bare `#` line is an option heading → :heading; the rest is prose.
#   - Other comment lines are Markdown prose (backticks, links, and fences are
#     already Markdown in the source) → :prose.
#   - Non-comment lines are YAML example code → :yaml. A deeply-indented comment
#     directly under a YAML line continues that line's trailing comment and
#     stays inside the :yaml block (see proxy.yml's `run:` options).
#
# Sections are cut at :h2 nodes when the file has dividers, at :heading nodes
# otherwise; nodes before the first cut form the preamble rendered under the
# page lead. Parsed once per file and memoized for the process's lifetime — the
# YAMLs only change with a gem checkout, never at runtime.
class ConfigDoc
  DOCS_DIR = Rails.root.join("../lib/dash/configuration/docs")

  DIVIDER      = /\A\s*#\s*=+\s*\z/
  COMMENT      = /\A\s*#/
  COMMENT_MARK = /\A\s*#\s?/
  BLANK        = /\A\s*\z/

  # A comment whose `#` sits this deep is a trailing-comment continuation of the
  # YAML line above it, not prose (prose comments sit at or near their block's
  # indentation; continuation comments align to a column ~35).
  CONTINUATION_COLUMN = 16

  # First heading line of a comment block: short and unpunctuated, followed by a
  # bare `#` line. Anything else stays prose.
  HEADING_MAX_LENGTH = 72
  HEADING_TERMINAL_PUNCTUATION = /[.:,;?]\z/

  Node    = Data.define(:kind, :text)
  Section = Data.define(:title, :nodes)

  class << self
    def all = slugs.map { |slug| self.for(slug) }

    def slugs
      Dir[DOCS_DIR.join("*.yml")].map { |path| File.basename(path, ".yml") }.sort
    end

    def for(slug)
      cache[slug] ||= begin
        path = DOCS_DIR.join("#{slug}.yml")
        raise ArgumentError, "no config doc for #{slug.inspect}" unless File.exist?(path)

        new(slug, File.read(path))
      end
    end

    private

    def cache = @cache ||= {}
  end

  attr_reader :slug, :title, :preamble, :sections

  def initialize(slug, source)
    @slug = slug
    nodes = parse(source.lines)
    @title = nodes.shift&.text if nodes.first&.kind == :heading
    cut_kind = nodes.any? { |node| node.kind == :h2 } ? :h2 : :heading
    @preamble = []
    @preamble << nodes.shift while nodes.any? && nodes.first.kind != cut_kind
    @sections = slice_sections(nodes, cut_kind)
  end

  private

  def slice_sections(nodes, cut_kind)
    nodes.slice_when { |_before, node| node.kind == cut_kind }
         .select { |group| group.first.kind == cut_kind }
         .map { |(head, *rest)| Section.new(title: head.text, nodes: rest) }
  end

  def parse(lines)
    nodes = []
    lines = lines.map(&:chomp)
    index = 0

    while index < lines.length
      line = lines[index]

      if line.match?(DIVIDER)
        index += 1
        index += 1 while lines[index]&.match?(BLANK)
        if lines[index]&.match?(COMMENT)
          nodes << Node.new(kind: :h2, text: strip_comment(lines[index]))
          index += 1
        end
        index += 1 while lines[index]&.match?(DIVIDER)
      elsif line.match?(COMMENT)
        index = consume_comment_block(lines, index, nodes)
      elsif line.match?(BLANK)
        index += 1
      else
        index = consume_yaml_block(lines, index, nodes)
      end
    end

    nodes
  end

  def consume_comment_block(lines, index, nodes)
    block = []
    while lines[index]&.match?(COMMENT) && !lines[index].match?(DIVIDER)
      block << strip_comment(lines[index])
      index += 1
    end
    block.shift while block.first&.empty?

    if heading?(block)
      nodes << Node.new(kind: :heading, text: block.shift)
      block.shift while block.first&.empty?
    end
    prose = block.join("\n").strip
    nodes << Node.new(kind: :prose, text: prose) unless prose.empty?
    index
  end

  # YAML example lines, keeping interior blanks and any deeply-indented comment
  # that continues a trailing comment from the line above. The block is dedented
  # to column zero (common leading indent removed, relative indent kept): the
  # examples sit under their parent keys in the source file, and a highlighter
  # given the raw columns renders a staggered, mis-lexed block.
  def consume_yaml_block(lines, index, nodes)
    block = []
    while (line = lines[index])
      if line.match?(COMMENT)
        break unless line.index("#") > CONTINUATION_COLUMN

        block << line
      elsif line.match?(BLANK)
        break unless lines[index + 1] && !lines[index + 1].match?(COMMENT) && !lines[index + 1].match?(BLANK)

        block << ""
      else
        block << line
      end
      index += 1
    end
    nodes << Node.new(kind: :yaml, text: dedent(block).join("\n"))
    index
  end

  def dedent(block)
    indent = block.reject(&:blank?).map { |line| line[/\A */].size }.min.to_i
    block.map { |line| line.blank? ? "" : line[indent..] }
  end

  def heading?(block)
    first, second = block
    first.present? && second&.empty? &&
      first.length <= HEADING_MAX_LENGTH && !first.match?(HEADING_TERMINAL_PUNCTUATION)
  end

  def strip_comment(line) = line.sub(COMMENT_MARK, "")
end
