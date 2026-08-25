require_relative "cli_test_case"

# Dash::Cli::Main::Migrate is exercised end-to-end through `dash migrate` in
# main_test.rb. These cases pin it as a plain object with no Thor instance
# involved: an earlier version delegated `say` to the shell, which works on Thor
# 1.4 (public) and raises NoMethodError on newer Thor (private). Output belongs
# to the Thor command; this class only returns [message, color] pairs.
class CliMigrateTest < CliTestCase
  test "runs without a shell and returns message and color pairs" do
    in_project_with(".kamal") do
      messages = Dash::Cli::Main::Migrate.new.run

      assert_equal [ [ "Moved .kamal to .dash", :green ] ], messages
      assert Dir.exist?(".dash")
    end
  end

  test "reports nothing to migrate with no colour" do
    in_project_with do
      assert_equal [ [ "No .kamal directory to migrate.", nil ] ], Dash::Cli::Main::Migrate.new.run
    end
  end

  test "refuses when both directories exist and moves nothing" do
    in_project_with(".dash", ".kamal") do
      messages = Dash::Cli::Main::Migrate.new.run

      assert_equal 1, messages.size
      assert_match "Both .dash and .kamal exist", messages.first.first
      assert_equal :yellow, messages.first.last
      assert Dir.exist?(".kamal")
    end
  end

  test "a dry run reports the move without performing it" do
    in_project_with(".kamal") do
      messages = Dash::Cli::Main::Migrate.new(dry_run: true).run

      assert_equal [ [ "Would move .kamal to .dash", nil ] ], messages
      assert Dir.exist?(".kamal")
      assert_not Dir.exist?(".dash")
    end
  end

  test "legacy env references are appended as their own lines" do
    in_project_with(".kamal") do
      File.write(".kamal/hooks", "echo $KAMAL_VERSION $KAMAL_HOSTS $KAMAL_VERSION")

      messages = Dash::Cli::Main::Migrate.new.run

      assert_equal [ "Moved .kamal to .dash", :green ], messages.first
      assert_match "Found legacy KAMAL_* references", messages[1].first
      assert_equal [ "  .dash/hooks: KAMAL_HOSTS, KAMAL_VERSION", nil ], messages[2]
    end
  end

  private
    def in_project_with(*directories)
      original_pwd = Dir.pwd

      Dir.mktmpdir do |tmpdir|
        directories.each { |directory| FileUtils.mkdir_p(File.join(tmpdir, directory)) }

        begin
          Dir.chdir(tmpdir)
          yield
        ensure
          Dir.chdir(original_pwd)
        end
      end
    end
end
