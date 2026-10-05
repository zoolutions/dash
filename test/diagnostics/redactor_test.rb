require "test_helper"

class DiagnosticsRedactorTest < ActiveSupport::TestCase
  setup do
    @redactor = Dash::Diagnostics::Redactor.new(secrets: { "DB_PASSWORD" => "hunter2-very-secret", "SHORT" => "abc" })
  end

  test "blanks every value under a key that names a credential, at any depth" do
    redacted = @redactor.redact(
      registry: { username: "dhh", password: "pw" },
      ssh_options: { keys: [ "~/.ssh/id_ed25519" ], key_data: [ "-----BEGIN" ], user: "root" },
      env: [ { "API_TOKEN" => "t" }, { "client_secret" => "s" } ]
    )

    assert_equal({ username: "dhh", password: "[REDACTED]" }, redacted[:registry])
    assert_equal({ keys: "[REDACTED]", key_data: "[REDACTED]", user: "root" }, redacted[:ssh_options])
    assert_equal [ { "API_TOKEN" => "[REDACTED]" }, { "client_secret" => "[REDACTED]" } ], redacted[:env]
  end

  test "blanks values under a key named after a secret" do
    assert_equal({ "DB_PASSWORD" => "[REDACTED]" }, @redactor.redact("DB_PASSWORD" => "anything"))
  end

  test "replaces a secret value wherever it appears inside a string" do
    redacted = @redactor.redact(
      clear: { "DATABASE_URL" => "postgres://app:hunter2-very-secret@db/app" },
      lines: [ "connected with hunter2-very-secret" ]
    )

    assert_equal "postgres://app:[REDACTED]@db/app", redacted[:clear]["DATABASE_URL"]
    assert_equal [ "connected with [REDACTED]" ], redacted[:lines]
  end

  test "leaves values shorter than the minimum alone, so a short secret cannot blank the output" do
    assert_equal "abc is the alphabet", @redactor.redact("abc is the alphabet")
  end

  test "renders sensitive values with their redaction" do
    assert_equal "[REDACTED]", @redactor.redact(Dash::Utils.sensitive("hunter"))
  end

  test "redacts text, for error messages" do
    assert_equal "docker login -p [REDACTED] failed", @redactor.redact_text("docker login -p hunter2-very-secret failed")
  end

  test "keeps everything else" do
    value = { hosts: [ "1.1.1.1" ], replicas: 2, healthy: true, at: nil }

    assert_equal value, @redactor.redact(value)
  end

  test "is built from the configuration's secrets" do
    with_test_secrets("secrets" => "MYSQL_ROOT_PASSWORD=mysql-root-secret") do
      config = Dash::Configuration.create_from(config_file: Pathname.new(File.expand_path("test/fixtures/deploy_with_accessories.yml")))
      redactor = Dash::Diagnostics::Redactor.for(config)

      assert_equal "root:[REDACTED]", redactor.redact_text("root:mysql-root-secret")
      assert_equal({ "MYSQL_ROOT_PASSWORD" => "[REDACTED]" }, redactor.redact("MYSQL_ROOT_PASSWORD" => "x"))
    end
  end
end
