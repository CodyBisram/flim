source "https://rubygems.org"

# Pinned to the exact version proven to work end-to-end. 2.236.x introduced a
# base64 .p8 regression ("invalid curve name") — avoid it until it's fixed upstream.
gem "fastlane", "2.235.0"

# 2.235.0 loads google-apis code that needs multi_json at runtime but doesn't
# declare it as a dependency, so bundler leaves it out. Add it explicitly.
gem "multi_json"
