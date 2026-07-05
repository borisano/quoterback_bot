Rollbar.configure do |config|
  config.access_token = ENV.fetch("ROLLBAR_ACCESS_TOKEN", nil)

  # Disable Rollbar if no token is configured (e.g. CI without secrets set)
  config.enabled = config.access_token.present?

  config.environment = Rails.env

  # Report the revision from git for source mapping / code context
  config.code_version = `git rev-parse --short HEAD 2>/dev/null`.strip.presence

  config.disable_monkey_patch = false

  # Scrub sensitive fields from request params and JSON bodies
  config.scrub_fields |= %w[
    TELEGRAM_BOT_TOKEN
    ROLLBAR_ACCESS_TOKEN
    password
    token
    secret
  ]
end
