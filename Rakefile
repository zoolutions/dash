desc "Build the gem and verify its contents"
task :verify do
  sh("gem build dash.gemspec --strict")
  gem_file = Dir["dash-*.gem"].max_by { |f| File.mtime(f) }
  sh("gem unpack #{gem_file} --target /tmp/gem-verify")
  puts "\n=== Gem contents ==="
  sh("find /tmp/gem-verify -type f | sort")
  sh("rm -rf /tmp/gem-verify #{gem_file}")
end

desc "Release a new version (rake release[1.2.3] or rake release[pre] or rake release[1.2.3,force])"
task :release, %i[version force] do |_t, args|
  require_relative "lib/kamal/version"

  def info(msg)    = puts "\e[34m→\e[0m #{msg}"
  def success(msg) = puts "\e[32m✓\e[0m #{msg}"
  def skip(msg)    = puts "\e[33m⊘\e[0m #{msg} \e[33m(skipped)\e[0m"
  def header(msg)  = puts "\n\e[1;36m#{msg}\e[0m\n#{"─" * msg.length}"

  new_version = args[:version]
  abort "\e[31mUsage: rake release[X.Y.Z] or rake release[X.Y.Z,force]\e[0m" unless new_version

  force = args[:force]&.to_s&.downcase == "force"

  dirty = `git status --porcelain`.strip
  abort "\e[31mAborting: working directory is not clean.\e[0m\n#{dirty}" unless dirty.empty?

  current = Kamal::VERSION
  prerelease = new_version.match?(/alpha|beta|rc|pre/) || new_version == "pre"

  if new_version == "pre"
    new_version = current
    prerelease = true
  end

  # The proxy image the gem will pull must exist BEFORE the gem releases —
  # integration tests and `dash proxy boot` pull it by this tag.
  minimum_version = File.read("lib/kamal/configuration/proxy/run.rb")[/MINIMUM_VERSION\s*=\s*"([^"]+)"/, 1]
  header "Proxy image gate"
  info "MINIMUM_VERSION is #{minimum_version} — must be published at ghcr.io/zoolutions/dash-proxy"
  unless system("docker buildx imagetools inspect ghcr.io/zoolutions/dash-proxy:#{minimum_version} >/dev/null 2>&1")
    abort "\e[31mAborting: ghcr.io/zoolutions/dash-proxy:#{minimum_version} is not pullable. Release the proxy first.\e[0m"
  end
  success "Proxy image #{minimum_version} is published"

  tag = "v#{new_version}"
  version_file = "lib/kamal/version.rb"

  title = "Release #{tag}"
  title += " (force)" if force
  header title
  info "Current version: #{current}"
  info "New version:     #{new_version}"
  info "Pre-release:     #{prerelease}"

  # Step 0: Force cleanup — delete existing release and tag
  if force
    header "Force cleanup"
    if system("gh release view #{tag} >/dev/null 2>&1")
      sh("gh release delete #{tag} --yes --cleanup-tag")
      success "Deleted release and remote tag #{tag}"
    else
      skip "No release #{tag} to delete"
    end

    if system("git rev-parse #{tag} >/dev/null 2>&1")
      sh("git tag -d #{tag}")
      success "Deleted local tag #{tag}"
    else
      skip "No local tag #{tag} to delete"
    end
  end

  # Step 1: Update version file
  header "Version"
  if new_version == current
    skip "Version already #{new_version}"
  else
    content = File.read(version_file)
    content.sub!(/VERSION = ".*"/, "VERSION = \"#{new_version}\"")
    File.write(version_file, content)
    success "Updated #{version_file}"
  end

  # Step 1b: Bump the path-gem pin in Gemfile.lock in place. The only thing a
  # version bump changes there is the dash pin, so a targeted edit beats a full
  # `bundle lock` re-resolve (which can trip over unrelated platform gems).
  header "Gemfile.lock pin"
  lock_content = File.read("Gemfile.lock")
  bumped = lock_content.gsub(/^(\s+dash) \([^)]*\)$/, "\\1 (#{new_version})")
  if bumped == lock_content
    skip "Gemfile.lock — no dash pin to bump"
  else
    File.write("Gemfile.lock", bumped)
    success "Bumped dash pin in Gemfile.lock"
  end

  # Step 2: Verify gem builds cleanly
  header "Build verification"
  sh("gem build dash.gemspec --strict")
  sh("rm -f dash-*.gem")
  success "Gem builds cleanly"

  # Step 3: Commit version bump
  header "Git commit"
  paths_to_stage = [ version_file, "Gemfile.lock" ]
  staged_changes = paths_to_stage.any? do |path|
    !`git diff #{path}`.strip.empty? || !`git diff --cached #{path}`.strip.empty?
  end
  if staged_changes
    paths_to_stage.each { |path| sh("git add #{path}") }
    sh("git commit -m 'chore: bump version to #{new_version}'")
    success "Committed version bump"
  else
    skip "No version change to commit"
  end

  # Step 4: Push to origin
  header "Git push"
  local_sha = `git rev-parse HEAD`.strip
  remote_sha = `git rev-parse origin/main 2>/dev/null`.strip
  if local_sha == remote_sha
    skip "origin/main already at #{local_sha[0..6]}"
  else
    sh("git push origin main")
    success "Pushed to origin/main"
  end

  # Step 5: Create release
  header "Release"
  tag_exists = system("git rev-parse #{tag} >/dev/null 2>&1")
  release_exists = system("gh release view #{tag} >/dev/null 2>&1")

  if release_exists
    skip "Release #{tag} already exists (use force to re-create)"
  elsif tag_exists
    info "Tag #{tag} exists, creating release from it"
    pre_flag = prerelease ? "--prerelease" : ""
    sh("gh release create #{tag} --generate-notes #{pre_flag}".strip)
    success "Release #{tag} created from existing tag"
  else
    pre_flag = prerelease ? "--prerelease" : ""
    sh("gh release create #{tag} --generate-notes --target main #{pre_flag}".strip)
    success "Release #{tag} created"
  end

  puts ""
  success "\e[1mRelease #{tag} complete!\e[0m CI will handle the rest:"
  puts "    • Run tests"
  puts "    • Build + verify gem"
  puts "    • Sign with Sigstore"
  puts "    • Publish to RubyGems"
  puts "    • Upload assets to the release"
end
