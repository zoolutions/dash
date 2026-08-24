require "test_helper"

class EnvFileTest < ActiveSupport::TestCase
  test "to_s" do
    env = {
      "foo" => "bar",
      "baz" => "haz"
    }

    assert_equal "foo=bar\nbaz=haz\n", \
      Dash::EnvFile.new(env).to_s
  end

  test "to_s won't escape '#'" do
    env = {
      "foo" => '#$foo',
      "bar" => '#{bar}'
    }

    assert_equal "foo=\#$foo\nbar=\#{bar}\n", \
      Dash::EnvFile.new(env).to_s
  end

  test "to_str won't escape chinese characters" do
    env = {
      "foo" => '你好 means hello, "欢迎" means welcome, that\'s simple! 😃 {smile}'
    }

    assert_equal "foo=你好 means hello, \"欢迎\" means welcome, that's simple! 😃 {smile}\n",
      Dash::EnvFile.new(env).to_s
  end

  test "to_s won't escape japanese characters" do
    env = {
      "foo" => 'こんにちは means hello, "ようこそ" means welcome, that\'s simple! 😃 {smile}'
    }

    assert_equal "foo=こんにちは means hello, \"ようこそ\" means welcome, that's simple! 😃 {smile}\n", \
      Dash::EnvFile.new(env).to_s
  end

  test "to_s won't escape korean characters" do
    env = {
      "foo" => '안녕하세요 means hello, "어서 오십시오" means welcome, that\'s simple! 😃 {smile}'
    }

    assert_equal "foo=안녕하세요 means hello, \"어서 오십시오\" means welcome, that's simple! 😃 {smile}\n", \
      Dash::EnvFile.new(env).to_s
  end

  test "to_s empty" do
    assert_equal "\n", Dash::EnvFile.new({}).to_s
  end

  test "to_s escaped newline" do
    env = {
      "foo" => "hello\\nthere"
    }

    assert_equal "foo=hello\\\\nthere\n", \
      Dash::EnvFile.new(env).to_s
  ensure
    ENV.delete "PASSWORD"
  end

  test "to_s newline" do
    env = {
      "foo" => "hello\nthere"
    }

    assert_equal "foo=hello\\nthere\n", \
      Dash::EnvFile.new(env).to_s
  ensure
    ENV.delete "PASSWORD"
  end

  test "stringIO conversion" do
    env = {
      "foo" => "bar",
      "baz" => "haz"
    }

    assert_equal "foo=bar\nbaz=haz\n", \
      StringIO.new(Dash::EnvFile.new(env)).read
  end
end
