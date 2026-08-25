require "test_helper"

class SecretsInlineCommandSubstitution < SecretAdapterTestCase
  test "inlines dash secrets commands" do
    Dash::Cli::Main.expects(:start).with { |command| command == [ "secrets", "fetch", "...", "--inline" ] }.returns("results")
    substituted = Dash::Secrets::Dotenv::InlineCommandSubstitution.call("FOO=$(dash secrets fetch ...)", nil, overwrite: false)
    assert_equal "FOO=results", substituted
  end

  test "inlines legacy kamal secrets commands" do
    Dash::Cli::Main.expects(:start).with { |command| command == [ "secrets", "fetch", "...", "--inline" ] }.returns("results")
    substituted = Dash::Secrets::Dotenv::InlineCommandSubstitution.call("FOO=$(kamal secrets fetch ...)", nil, overwrite: false)
    assert_equal "FOO=results", substituted
  end

  test "executes other commands" do
    Dash::Secrets::Dotenv::InlineCommandSubstitution.stubs(:`).with("blah").returns("results")
    substituted = Dash::Secrets::Dotenv::InlineCommandSubstitution.call("FOO=$(blah)", nil, overwrite: false)
    assert_equal "FOO=results", substituted
  end

  test "handles escaped parentheses in command arguments" do
    command_with_escaped_parens = 'dash secrets extract KEY1 \{\"KEY1\":\"pass\)word\"\}'
    Dash::Cli::Main.expects(:start).with { |cmd|
      cmd.first(3) == [ "secrets", "extract", "KEY1" ] &&
      cmd[3] == '{"KEY1":"pass)word"}'  # shellsplit should unescape
    }.returns("pass)word")

    substituted = Dash::Secrets::Dotenv::InlineCommandSubstitution.call(
      "KEY1=$(#{command_with_escaped_parens})", nil, overwrite: false
    )
    assert_equal "KEY1=pass)word", substituted
  end
end
