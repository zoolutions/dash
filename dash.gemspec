require_relative "lib/kamal/version"

Gem::Specification.new do |spec|
  spec.name        = "dash"
  spec.version     = Kamal::VERSION
  spec.authors     = [ "Mikael Henriksson" ]
  spec.email       = "mikael@zoolutions.llc"
  spec.homepage    = "https://github.com/zoolutions/dash"
  spec.summary     = "Deploy web apps in containers to servers running Docker with zero downtime."
  spec.license     = "MIT"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/zoolutions/dash/tree/main"
  spec.metadata["changelog_uri"] = "https://github.com/zoolutions/dash/releases"
  spec.metadata["bug_tracker_uri"] = "https://github.com/zoolutions/dash/issues"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*", "MIT-LICENSE", "README.md"]
  spec.executables = %w[ dash ]
  spec.required_ruby_version = ">= 3.2"

  spec.add_dependency "activesupport", ">= 7.0"
  spec.add_dependency "sshkit", ">= 1.23.0", "< 2.0"
  spec.add_dependency "net-ssh", "~> 7.3"
  spec.add_dependency "thor", "~> 1.3"
  spec.add_dependency "dotenv", "~> 3.1"
  spec.add_dependency "zeitwerk", ">= 2.6.18", "< 3.0"
  spec.add_dependency "ed25519", "~> 1.4"
  spec.add_dependency "bcrypt_pbkdf", "~> 1.0"
  spec.add_dependency "concurrent-ruby", "~> 1.2"
  spec.add_dependency "base64", "~> 0.2"
end
