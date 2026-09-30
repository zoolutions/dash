desc "Build the gem and verify its contents"
task :verify do
  sh("gem build dash.gemspec --strict")
  gem_file = Dir["dash-*.gem"].max_by { |f| File.mtime(f) }
  sh("gem unpack #{gem_file} --target /tmp/gem-verify")
  puts "\n=== Gem contents ==="
  sh("find /tmp/gem-verify -type f | sort")
  sh("rm -rf /tmp/gem-verify #{gem_file}")
end

# `rake release[X.Y.Z]` lives in rakelib/release.rake (shared verbatim across the
# zoolutions gems); `bin/release` is its interactive front door.
namespace :release do
  # The proxy image the gem will pull must exist BEFORE the gem releases —
  # integration tests and `dash proxy boot` pull it by this tag.
  task :preflight, [ :version ] do
    minimum_version = File.read("lib/dash/configuration/proxy/run.rb")[/MINIMUM_VERSION\s*=\s*"([^"]+)"/, 1]
    ReleaseKit.info "MINIMUM_VERSION is #{minimum_version} — must be published at ghcr.io/zoolutions/dash-proxy"
    unless system("docker buildx imagetools inspect ghcr.io/zoolutions/dash-proxy:#{minimum_version} >/dev/null 2>&1")
      ReleaseKit.fail!("ghcr.io/zoolutions/dash-proxy:#{minimum_version} is not pullable. Release the proxy first.")
    end
    ReleaseKit.success "Proxy image #{minimum_version} is published"
  end
end
