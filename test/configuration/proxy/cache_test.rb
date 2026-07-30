require "test_helper"

class ConfigurationProxyCacheTest < ActiveSupport::TestCase
  setup do
    ENV["RAILS_MASTER_KEY"] = "456"
    ENV["VERSION"] = "missing"

    @deploy = {
      service: "app", image: "dhh/app", registry: { "username" => "dhh", "password" => "secret" },
      builder: { "arch" => "amd64" }, servers: [ "1.1.1.1" ]
    }
  end

  # Policy — proxy.cache, per service

  test "no cache block leaves the deploy command unchanged" do
    options = deploy_options({})

    assert_not options.key?(:cache)
    assert_not options.key?(:"cache-max-ttl")
    assert_not options.key?(:"cache-allow-set-cookie")
  end

  # Everything but --cache stays out until its key is set: the defaults live in
  # kamal-proxy, the same convention healthcheck_path follows.
  test "enabled alone emits only --cache" do
    options = deploy_options "enabled" => true

    assert_equal true, options[:cache]
    assert_equal [ :cache ], options.keys.grep(/cache/)
  end

  test "durations use the seconds convention and sizes are byte counts" do
    options = deploy_options "enabled" => true, "max_ttl" => 300, "max_body" => 1_048_576, "max_variants" => 8

    assert_equal "300s", options[:"cache-max-ttl"]
    assert_equal 1_048_576, options[:"cache-max-body"]
    assert_equal 8, options[:"cache-max-variants"]
  end

  test "vary_headers and vary_cookies become repeated flags" do
    config = configuration "cache" => {
      "enabled" => true,
      "vary_headers" => [ "Accept-Encoding", "Accept-Language" ],
      "vary_cookies" => [ "locale" ]
    }

    args = config.proxy.deploy_command_args(target: "1.1.1.1")

    assert_includes args, "--cache-vary-header=\"Accept-Encoding\""
    assert_includes args, "--cache-vary-header=\"Accept-Language\""
    assert_includes args, "--cache-vary-cookie=\"locale\""
  end

  test "allow_set_cookie only appears when opted in" do
    assert_equal true, deploy_options("enabled" => true, "allow_set_cookie" => true)[:"cache-allow-set-cookie"]
    assert_not deploy_options("enabled" => true, "allow_set_cookie" => false).key?(:"cache-allow-set-cookie")
  end

  # Store — proxy.run.cache, proxy-wide

  test "no run cache block leaves the run command unchanged" do
    assert_equal "kamal-proxy run --recheck-targets-on-restore", run_config({}).run_command
  end

  test "store settings become kamal-proxy run flags" do
    run = run_config "store" => "redis://cache.example.com:6379/0", "store_timeout" => 2, "memory_size" => 134_217_728

    assert_equal "kamal-proxy run --recheck-targets-on-restore " \
      "--cache-store \"redis://cache.example.com:6379/0\" --cache-store-timeout \"2s\" " \
      "--cache-memory-size \"134217728\"", run.run_command
  end

  # Negative lease values switch cross-node coalescing off, and pflag takes the
  # next argument for a `--flag value` pair without checking for a leading dash.
  test "negative lease durations survive the space-separated rendering" do
    run = run_config "store" => "redis://cache.example.com:6379/0", "lease_ttl" => -1, "lease_wait" => 0

    assert_match "--cache-lease-ttl \"-1s\"", run.run_command
    assert_match "--cache-lease-wait \"0s\"", run.run_command
  end

  test "config_digest changes when the store changes" do
    memory = run_config("store" => "memory").config_digest
    redis = run_config("store" => "redis://cache.example.com:6379/0").config_digest

    assert_not_equal memory, redis
    assert_not_equal run_config({}).config_digest, memory
  end

  # Validation

  test "policy keys without enabled are a config error" do
    error = assert_raises(Kamal::ConfigurationError) { configuration "cache" => { "max_ttl" => 300 } }

    assert_equal "proxy/cache: max_ttl has no effect without enabled: true - " \
      "kamal-proxy ignores the cache policy entirely when --cache is absent", error.message
  end

  test "enabled false with policy keys is the same error" do
    error = assert_raises(Kamal::ConfigurationError) do
      configuration "cache" => { "enabled" => false, "vary_cookies" => [ "locale" ] }
    end

    assert_equal "proxy/cache: vary_cookies has no effect without enabled: true - " \
      "kamal-proxy ignores the cache policy entirely when --cache is absent", error.message
  end

  test "an unsupported store fails at config time" do
    error = assert_raises(Kamal::ConfigurationError) do
      configuration "run" => { "cache" => { "store" => "memcached://cache.example.com" } }
    end

    assert_equal "proxy/run/cache: store must be 'memory' or a redis:// or rediss:// URL", error.message
  end

  test "memory and redis stores are accepted" do
    assert configuration("run" => { "cache" => { "store" => "memory" } })
    assert configuration("run" => { "cache" => { "store" => "redis://cache.example.com:6379/0" } })
    assert configuration("run" => { "cache" => { "store" => "rediss://cache.example.com:6379/0" } })
  end

  private
    def configuration(proxy_config)
      Kamal::Configuration.new @deploy.merge(proxy: proxy_config)
    end

    def deploy_options(cache_config)
      configuration(cache_config.present? ? { "cache" => cache_config } : {}).proxy.deploy_options
    end

    def run_config(cache_config)
      config = Kamal::Configuration.new(@deploy)
      run = cache_config.present? ? { "cache" => cache_config } : {}

      Kamal::Configuration::Proxy::Run.new(config, run_config: run)
    end
end
