require "vcr"

VCR.configure do |config|
  config.cassette_library_dir = "spec/vcr_cassettes"
  config.hook_into :webmock
  config.configure_rspec_metadata!
  config.default_cassette_options = {
    record: :none,
    match_requests_on: [:method, :host, :path]
  }

  config.filter_sensitive_data("<TELEGRAM_BOT_TOKEN>") { ENV["TELEGRAM_BOT_TOKEN"] }
end
