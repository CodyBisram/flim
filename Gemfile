source "https://rubygems.org"

# Pinned to the exact version proven to work end-to-end. 2.236.x introduced a
# base64 .p8 regression ("invalid curve name") — avoid it until it's fixed upstream.
gem "fastlane", "2.235.0"

# 2.235.0 loads google-apis code that needs multi_json at runtime but doesn't
# declare it as a dependency, so bundler leaves it out. Add it explicitly.
gem "multi_json"

# Gemfile.lock is committed and is resolved under CI's Ruby (3.3), never a dev machine's: CI runs
# bundler in deployment mode against it, with the App Store Connect key and the match secrets in
# the environment, so nothing it installs may be chosen at run time. To change a gem, edit this file
# and regenerate the lock in a container with that Ruby:
#   docker run --rm -v "$PWD":/w -w /w ruby:3.3 bundle lock --add-platform arm64-darwin x86_64-darwin ruby
