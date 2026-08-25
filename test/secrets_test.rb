require "test_helper"

class SecretsTest < ActiveSupport::TestCase
  test "fetch" do
    with_test_secrets("secrets" => "SECRET=ABC") do
      assert_equal "ABC", Dash::Secrets.new(secrets_path: ".dash/secrets")["SECRET"]
    end
  end

  test "synchronized_fetch" do
    with_test_secrets("secrets" => "SECRET=ABC") do
      assert_equal "ABC", Dash::Secrets.new(secrets_path: ".dash/secrets").send(:synchronized_fetch, "SECRET")
    end
  end

  test "key?" do
    with_test_secrets("secrets" => "SECRET1=ABC") do
      assert Dash::Secrets.new(secrets_path: ".dash/secrets").key?("SECRET1")
      assert_not Dash::Secrets.new(secrets_path: ".dash/secrets").key?("SECRET2")
    end
  end

  test "command interpolation" do
    with_test_secrets("secrets" => "SECRET=$(echo ABC)") do
      assert_equal "ABC", Dash::Secrets.new(secrets_path: ".dash/secrets")["SECRET"]
    end
  end

  test "variable references" do
    with_test_secrets("secrets" => "SECRET1=ABC\nSECRET2=${SECRET1}DEF") do
      assert_equal "ABC", Dash::Secrets.new(secrets_path: ".dash/secrets")["SECRET1"]
      assert_equal "ABCDEF", Dash::Secrets.new(secrets_path: ".dash/secrets")["SECRET2"]
    end
  end

  test "env references" do
    with_test_secrets("secrets" => "SECRET1=$SECRET1") do
      ENV["SECRET1"] = "ABC"
      assert_equal "ABC", Dash::Secrets.new(secrets_path: ".dash/secrets")["SECRET1"]
    end
  end

  test "secrets file value overrides env" do
    with_test_secrets("secrets" => "SECRET1=DEF") do
      ENV["SECRET1"] = "ABC"
      assert_equal "DEF", Dash::Secrets.new(secrets_path: ".dash/secrets")["SECRET1"]
    end
  end

  test "destinations" do
    with_test_secrets("secrets.dest" => "SECRET=DEF", "secrets" => "SECRET=ABC", "secrets-common" => "SECRET=GHI\nSECRET2=JKL") do
      assert_equal "ABC", Dash::Secrets.new(secrets_path: ".dash/secrets")["SECRET"]
      assert_equal "DEF", Dash::Secrets.new(secrets_path: ".dash/secrets", destination: "dest")["SECRET"]
      assert_equal "GHI", Dash::Secrets.new(secrets_path: ".dash/secrets", destination: "nodest")["SECRET"]

      assert_equal "JKL", Dash::Secrets.new(secrets_path: ".dash/secrets")["SECRET2"]
      assert_equal "JKL", Dash::Secrets.new(secrets_path: ".dash/secrets", destination: "dest")["SECRET2"]
      assert_equal "JKL", Dash::Secrets.new(secrets_path: ".dash/secrets", destination: "nodest")["SECRET2"]
    end
  end

  test "no secrets files" do
    with_test_secrets do
      error = assert_raises(Dash::ConfigurationError) do
        Dash::Secrets.new(secrets_path: ".dash/secrets")["SECRET"]
      end
      assert_equal "Secret 'SECRET' not found, no secret files (.dash/secrets-common, .dash/secrets) provided", error.message

      error = assert_raises(Dash::ConfigurationError) do
        Dash::Secrets.new(secrets_path: ".dash/secrets", destination: "dest")["SECRET"]
      end
      assert_equal "Secret 'SECRET' not found, no secret files (.dash/secrets-common, .dash/secrets.dest) provided", error.message
    end
  end

  test "custom secrets_path" do
    Dir.mktmpdir do |tmpdir|
      Dir.chdir(tmpdir) do
        FileUtils.mkdir_p("custom/path")
        File.write("custom/path/secrets", "SECRET=CUSTOM")

        assert_equal "CUSTOM", Dash::Secrets.new(secrets_path: "custom/path/secrets")["SECRET"]
      end
    end
  end

  test "custom secrets_path with destination" do
    Dir.mktmpdir do |tmpdir|
      Dir.chdir(tmpdir) do
        FileUtils.mkdir_p("custom/path")
        File.write("custom/path/secrets", "SECRET=BASE")
        File.write("custom/path/secrets.prod", "SECRET=PROD")

        assert_equal "BASE", Dash::Secrets.new(secrets_path: "custom/path/secrets")["SECRET"]
        assert_equal "PROD", Dash::Secrets.new(secrets_path: "custom/path/secrets", destination: "prod")["SECRET"]
      end
    end
  end

  test "custom secrets_path with common file" do
    Dir.mktmpdir do |tmpdir|
      Dir.chdir(tmpdir) do
        FileUtils.mkdir_p("custom/path")
        File.write("custom/path/secrets-common", "COMMON=SHARED\nSECRET=COMMON")
        File.write("custom/path/secrets", "SECRET=OVERRIDE")

        secrets = Dash::Secrets.new(secrets_path: "custom/path/secrets")
        assert_equal "SHARED", secrets["COMMON"]
        assert_equal "OVERRIDE", secrets["SECRET"]
      end
    end
  end

  test "default secrets_path" do
    with_test_secrets("secrets" => "SECRET=ABC") do
      assert_equal "ABC", Dash::Secrets.new["SECRET"]
    end
  end

  test "default secrets_path falls back to the legacy .kamal directory" do
    with_legacy_test_secrets("secrets" => "SECRET=ABC") do
      assert_equal "ABC", Dash::Secrets.new["SECRET"]
    end
  end

  test "default secrets_path prefers .dash when both directories exist" do
    with_test_secrets("secrets" => "SECRET=NEW") do
      FileUtils.mkdir_p(".kamal")
      File.write(".kamal/secrets", "SECRET=OLD")

      assert_equal "NEW", Dash::Secrets.new["SECRET"]
    end
  end

  test "custom secrets_path error message" do
    Dir.mktmpdir do |tmpdir|
      Dir.chdir(tmpdir) do
        error = assert_raises(Dash::ConfigurationError) do
          Dash::Secrets.new(secrets_path: "custom/path/secrets")["SECRET"]
        end
        assert_equal "Secret 'SECRET' not found, no secret files (custom/path/secrets-common, custom/path/secrets) provided", error.message
      end
    end
  end
end
