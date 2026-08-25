require "test_helper"
require "digest"

# `lib/dash/sshkit_with_ext.rb` prepends modules that replace two SSHKit runner methods
# wholesale — neither calls `super`, because both need to change what happens *inside* the
# loop rather than around it.
#
# A loud break (upstream renames `hosts`, `block`, `group_size`, `wait_interval`) raises at
# deploy time and `test/sshkit_on_roles_test.rb` catches it, because that suite drives the
# real runners. A silent one does not: if upstream changes what `execute` *means* — adds
# retries, aggregates errors, fixes the very defect `CompleteAll` exists to work around —
# our copy still wins unconditionally and every test still passes. We would ship a stale
# fork of upstream's method forever and only hear about it in a bug report.
#
# So pin a digest of each upstream body we copied from. When one trips, read the new
# upstream method and decide: is our patch still needed, can we drop it, or must the change
# be ported into our copy? Then re-baseline the digest in the same commit.
class SshkitPatchDriftTest < ActiveSupport::TestCase
  # Baselined against sshkit 1.25.x. CI deletes Gemfile.lock and resolves fresh, so these
  # run against whatever `>= 1.23.0, < 2.0` currently yields — not against the lockfile.
  PATCHED_METHODS = {
    # patched by SSHKit::Runner::Parallel::CompleteAll
    [ "SSHKit::Runner::Parallel", :execute ] => "ceeebb9a39714f2a7546bb0d39a325d971c1fa2f2fec54c6fc316712a5de0e40",
    # patched by SSHKit::Runner::Group::NoTrailingWait
    [ "SSHKit::Runner::Group", :execute ] => "c6af8886fd9617f9154a91cf3a5aa7bf538e9100f8ccdf6abefbfa8c9dcf6226"
  }

  PATCHED_METHODS.each do |(class_name, method_name), digest|
    test "upstream #{class_name}##{method_name} has not drifted from the body we patched" do
      klass = Object.const_get(class_name)
      method = upstream_instance_method(klass, method_name)

      assert_not_nil method,
        "#{class_name} no longer defines its own ##{method_name} — the Kamal patch is now " \
        "overriding an inherited or missing method. Re-read the upstream runner."

      source = method_source(method)

      assert_equal digest, Digest::SHA256.hexdigest(source), <<~MESSAGE
        Upstream #{class_name}##{method_name} changed since we copied it into
        lib/dash/sshkit_with_ext.rb. Our prepended module replaces it wholesale, so this
        change is currently being dropped on the floor.

        Read the new upstream body, then either drop our patch, port the change into it, or
        confirm it is irrelevant — then re-baseline PATCHED_METHODS in the same commit.

        #{method.source_location.join(":")} (sshkit #{sshkit_version})

        #{source.gsub(/^/, "  ")}
      MESSAGE
    end
  end

  private
    # The prepended module owns `instance_method(:execute)`; walk the super chain back to
    # the method the class itself defines. Walking (rather than a single `super_method`)
    # keeps this correct if a second module is ever prepended in front of ours.
    def upstream_instance_method(klass, name)
      method = klass.instance_method(name)
      method = method.super_method while method && method.owner != klass
      method
    end

    # No `method_source` gem and no `RubyVM::AbstractSyntaxTree.of` (Prism-compiled iseqs
    # refuse it), so slice the definition out by indentation: from `def` to the `end` that
    # lines up with it. `rstrip` normalizes trailing whitespace and line endings so a
    # cosmetic diff in the gem checkout doesn't cry wolf.
    def method_source(method)
      file, line = method.source_location
      lines = File.readlines(file)
      first = line - 1
      indent = lines[first][/\A[ \t]*/]
      last = first

      last += 1 until last >= lines.size || lines[last].rstrip == "#{indent}end"

      assert_operator last, :<, lines.size,
        "Could not find the end of #{method.owner}##{method.name} in #{file}"

      lines[first..last].map(&:rstrip).join("\n")
    end

    def sshkit_version
      Gem.loaded_specs["sshkit"]&.version || "unknown"
    end
end
