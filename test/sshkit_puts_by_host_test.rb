require "test_helper"

# `puts_by_host` runs on one SSHKit thread per host, and `bin/dash` writes stdout unbuffered.
# Each separate write is a point where another host's output can land, so a header written
# apart from its output can end up labelling a different host's lines.
class SshkitPutsByHostTest < ActiveSupport::TestCase
  class WriteRecorder < StringIO
    attr_reader :writes

    def initialize
      super
      @writes = []
    end

    def write(*parts)
      @writes << parts.join
      super
    end
  end

  test "writes the host header and its output in a single write" do
    writes = recording_writes { backend.puts_by_host("1.1.1.1", "Today") }

    assert_equal [ "App Host: 1.1.1.1\nToday\n\n" ], writes
  end

  test "quiet writes only the output" do
    writes = recording_writes { backend.puts_by_host("1.1.1.1", "Today", quiet: true) }

    assert_equal [ "Today\n\n" ], writes
  end

  private
    def backend
      SSHKit::Backend::Printer.new(SSHKit::Host.new("1.1.1.1"))
    end

    def recording_writes
      original, $stdout = $stdout, WriteRecorder.new
      yield
      $stdout.writes
    ensure
      $stdout = original
    end
end
