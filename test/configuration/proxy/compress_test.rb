require "test_helper"

class ConfigurationProxyCompressTest < ActiveSupport::TestCase
  setup do
    @deploy = {
      service: "app", image: "dhh/app", registry: { "username" => "dhh", "password" => "secret" },
      builder: { "arch" => "amd64" }, servers: [ "1.1.1.1" ]
    }
  end

  test "no compress key leaves the deploy command unchanged" do
    assert_empty deploy_options(nil).keys.grep(/compress/)
  end

  test "compress false emits nothing" do
    assert_empty deploy_options(false).keys.grep(/compress/)
  end

  # --compress is a list of encodings, not a switch, so the shorthand has to name
  # them. Bare --compress would swallow the next flag as its value.
  test "the boolean shorthand offers the default encodings and nothing else" do
    options = deploy_options(true)

    assert_equal Dash::Configuration::Proxy::DEFAULT_COMPRESSION_ENCODINGS, options[:compress]
    assert_equal [ :compress ], options.keys.grep(/compress/)
  end

  test "the default encodings are best-ratio first" do
    assert_equal %w[ zstd br gzip ], Dash::Configuration::Proxy::DEFAULT_COMPRESSION_ENCODINGS
  end

  test "enabled in the block form is the same as the shorthand" do
    assert_equal deploy_options(true), deploy_options("enabled" => true)
  end

  test "encodings alone enables compression" do
    options = deploy_options("encodings" => [ "gzip" ])

    assert_equal [ "gzip" ], options[:compress]
  end

  # An explicit off switch beats an implicit on: `enabled: false` with tuned
  # settings kept around is "temporarily off", not "on because encodings imply
  # it" - it used to silently keep compression running.
  test "enabled false wins over encodings" do
    assert_empty deploy_options("enabled" => false, "encodings" => [ "gzip" ]).keys.grep(/compress/)
    assert_empty deploy_options("enabled" => false, "min_length" => 1024).keys.grep(/compress/)
  end

  test "encodings reach the proxy as repeated flags in order" do
    args = configuration("compress" => { "encodings" => [ "br", "gzip" ] })
      .proxy.deploy_command_args(target: "1.1.1.1")

    assert_equal [ "--compress=\"br\"", "--compress=\"gzip\"" ], args.grep(/^--compress=/)
  end

  test "content_types reach the proxy as repeated flags" do
    args = configuration("compress" => { "enabled" => true, "content_types" => [ "text/html", "application/json" ] })
      .proxy.deploy_command_args(target: "1.1.1.1")

    assert_includes args, "--compress-content-type=\"text/html\""
    assert_includes args, "--compress-content-type=\"application/json\""
  end

  test "min_length is a byte count" do
    assert_equal 1024, deploy_options("enabled" => true, "min_length" => 1024)[:"compress-min-length"]
  end

  test "an empty block enables nothing" do
    assert_empty deploy_options({}).keys.grep(/compress/)
  end

  # Validation — kamal-proxy rejects each of these, after the SSH round-trip

  test "min_length without compression is a config error" do
    error = assert_raises(Dash::ConfigurationError) { configuration "compress" => { "min_length" => 1024 } }

    assert_equal "proxy/compress: min_length has no effect without compression - " \
      "set enabled: true or name the encodings", error.message
  end

  test "content_types without compression is a config error" do
    error = assert_raises(Dash::ConfigurationError) do
      configuration "compress" => { "content_types" => [ "text/html" ] }
    end

    assert_equal "proxy/compress: content_types has no effect without compression - " \
      "set enabled: true or name the encodings", error.message
  end

  # Unlike an absent `enabled` with orphaned tuning (above), an explicit false
  # is a deliberate off switch - the settings stay for flipping it back on.
  test "enabled false with tuned settings is legal and off" do
    config = configuration "compress" => { "enabled" => false, "content_types" => [ "text/html" ] }

    assert_empty config.proxy.deploy_options.keys.grep(/compress/)
  end

  test "an unsupported encoding is a config error" do
    error = assert_raises(Dash::ConfigurationError) { configuration "compress" => { "encodings" => [ "lzma" ] } }

    assert_equal "proxy/compress: unsupported encoding 'lzma'. Supported encodings: gzip, br, zstd", error.message
  end

  test "brotli is accepted as an alias for br" do
    assert configuration("compress" => { "encodings" => [ "brotli" ] })
  end

  test "a negative min_length is a config error" do
    error = assert_raises(Dash::ConfigurationError) do
      configuration "compress" => { "enabled" => true, "min_length" => -1 }
    end

    assert_equal "proxy/compress: min_length cannot be negative", error.message
  end

  test "a malformed content type is a config error" do
    error = assert_raises(Dash::ConfigurationError) do
      configuration "compress" => { "enabled" => true, "content_types" => [ "text" ] }
    end

    assert_equal "proxy/compress: content_types entry 'text' must be a media type such as text/html or text/*",
      error.message
  end

  test "type wildcards are accepted and main-type wildcards are not" do
    assert configuration("compress" => { "enabled" => true, "content_types" => [ "text/*" ] })

    assert_raises(Dash::ConfigurationError) do
      configuration "compress" => { "enabled" => true, "content_types" => [ "*/json" ] }
    end
  end

  private
    def configuration(proxy_config)
      Dash::Configuration.new @deploy.merge(proxy: proxy_config)
    end

    def deploy_options(compress_config)
      configuration(compress_config.nil? ? {} : { "compress" => compress_config }).proxy.deploy_options
    end
end
