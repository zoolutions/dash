require "test_helper"

class EagerRequiresTest < ActiveSupport::TestCase
  # Dash::Configuration::Proxy::Run.digest calls Digest::SHA256 from inside
  # `on(DASH.proxy_hosts)` — one SSHKit thread per host, all reaching for the
  # constant at once. If `digest` is only autoloaded on first reference, those
  # threads race the extension's class hierarchy and one loses with
  # "Digest::Base cannot be directly inherited in Ruby", failing `dash proxy boot`
  # on a random host. Intermittent, so no ordinary test catches it.
  #
  # This has to run in a subprocess: the test suite pulls in `digest` through
  # other paths (test/sshkit_patch_drift_test.rb requires it outright), so an
  # in-process `defined?(Digest)` would pass whether or not lib/dash.rb requires
  # it — exactly the false green this test exists to prevent.
  test "requiring kamal loads digest, so SSHKit threads cannot race its autoload" do
    loaded = sh_ruby 'require "dash"; print defined?(Digest::SHA256) ? "loaded" : "missing"'

    assert_equal "loaded", loaded,
      "lib/dash.rb no longer requires \"digest\". Dash::Configuration::Proxy::Run.digest " \
      "is called concurrently from Dash::Cli::Proxy#boot, and a lazy autoload there fails " \
      "intermittently with \"Digest::Base cannot be directly inherited in Ruby\"."
  end

  private
    def sh_ruby(script)
      lib = File.expand_path("../lib", __dir__)
      output = IO.popen([ RbConfig.ruby, "-I#{lib}", "-e", script ], err: :err, &:read)

      assert_predicate $?, :success?, "subprocess failed: #{output}"
      output
    end
end
