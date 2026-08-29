require "test_helper"

class TimingsTest < ActiveSupport::TestCase
  setup do
    @timings = Dash::Timings.new
  end

  test "empty by default" do
    assert_not @timings.any?
    assert_equal [], @timings.lines
  end

  test "phase records its name and wall time" do
    @timings.phase("Pull app image") { }

    assert @timings.any?
    assert_match(/\A  Pull app image\s+\d+\.\ds\z/, @timings.lines.sole)
  end

  test "phase records even when the block raises" do
    assert_raises(RuntimeError) { @timings.phase("Boot") { raise "boom" } }

    assert_match(/Boot\s+\d+\.\ds/, @timings.lines.sole)
  end

  test "nested phases print as a tree in start order" do
    @timings.phase("Boot") do
      @timings.phase("web 1.1.1.1", depth: 1) { }
      @timings.phase("web 1.1.1.2", depth: 1) { }
    end

    assert_match(/\A  Boot\s+\d+\.\ds\z/, @timings.lines[0])
    assert_match(/\A    web 1\.1\.1\.1\s+\d+\.\ds\z/, @timings.lines[1])
    assert_match(/\A    web 1\.1\.1\.2\s+\d+\.\ds\z/, @timings.lines[2])
  end

  test "the block can annotate its entry" do
    @timings.phase("web 1.1.1.1") { |entry| entry.detail = "healthy after 0.5s" }

    assert_match(/web 1\.1\.1\.1\s+\d+\.\ds \(healthy after 0\.5s\)\z/, @timings.lines.sole)
  end

  test "phases from many threads all land" do
    threads = 20.times.map { |i| Thread.new { @timings.phase("host #{i}") { } } }
    threads.each(&:join)

    assert_equal 20, @timings.lines.size
  end
end
