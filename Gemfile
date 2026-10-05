source "https://rubygems.org"
git_source(:github) { |repo| "https://github.com/#{repo}.git" }

gemspec

group :development do
  gem "debug"
  gem "minitest", "< 6"
  gem "mocha"
  gem "railties"
  gem "mcp", "~> 1.6" # optional at runtime (`dash mcp` lazy-requires it); here so CI runs test/mcp
end

group :rubocop do
  gem "rubocop-rails-omakase", require: false
end
