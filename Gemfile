source "https://rubygems.org"
git_source(:github) { |repo| "https://github.com/#{repo}.git" }

gemspec

group :development do
  gem "debug"
  gem "minitest", "< 6"
  gem "mocha"
  gem "railties"
end

group :rubocop do
  gem "rubocop-rails-omakase", require: false
end
