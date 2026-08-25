require "test_helper"

class ProjectDirectoryTest < ActiveSupport::TestCase
  test "resolves to .dash when it exists" do
    in_project_with(".dash") do
      assert_equal ".dash", Dash::ProjectDirectory.path
      assert_not Dash::ProjectDirectory.legacy?
    end
  end

  test "falls back to .kamal when only the legacy directory exists" do
    in_project_with(".kamal") do
      assert_equal ".kamal", Dash::ProjectDirectory.path
      assert Dash::ProjectDirectory.legacy?
    end
  end

  test "prefers .dash when both exist" do
    in_project_with(".dash", ".kamal") do
      assert_equal ".dash", Dash::ProjectDirectory.path
      assert_not Dash::ProjectDirectory.legacy?
    end
  end

  test "resolves to .dash when neither exists" do
    in_project_with do
      assert_equal ".dash", Dash::ProjectDirectory.path
      assert_not Dash::ProjectDirectory.legacy?
    end
  end

  test "joins paths onto the resolved directory" do
    in_project_with(".kamal") do
      assert_equal ".kamal/secrets", Dash::ProjectDirectory.join("secrets")
      assert_equal ".kamal/hooks/pre-deploy", Dash::ProjectDirectory.join("hooks", "pre-deploy")
    end
  end

  # A project holding only `.dash/secrets-common` still resolves to `.dash`: the fallback tests the
  # directory, not the `secrets` file, because Dash::Secrets synthesizes the `-common` and
  # `.<destination>` filenames from the base path.
  test "resolves to .dash when it holds only a secrets-common file" do
    in_project_with(".dash", ".kamal") do
      File.write(".dash/secrets-common", "FOO=1")
      File.write(".kamal/secrets", "FOO=2")

      assert_equal ".dash", Dash::ProjectDirectory.path
    end
  end

  # Not memoized: `dash migrate` moves the directory inside a single process, so a cached answer
  # would be wrong for the rest of that invocation.
  test "re-resolves after the directory moves" do
    in_project_with(".kamal") do
      assert_equal ".kamal", Dash::ProjectDirectory.path

      FileUtils.mv(".kamal", ".dash")

      assert_equal ".dash", Dash::ProjectDirectory.path
    end
  end

  private
    def in_project_with(*directories)
      Dir.mktmpdir do |tmpdir|
        Dir.chdir(tmpdir) do
          directories.each { |directory| FileUtils.mkdir_p(directory) }
          yield
        end
      end
    end
end
