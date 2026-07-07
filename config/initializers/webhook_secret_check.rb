require "webhook_secret_check"

# See lib/webhook_secret_check.rb — refuse to boot in production without a
# webhook secret, but let the asset-precompile build (SECRET_KEY_BASE_DUMMY) pass.
WebhookSecretCheck.verify!(
  production: Rails.env.production?,
  secret:     ENV["TELEGRAM_WEBHOOK_SECRET"],
  dummy:      ENV["SECRET_KEY_BASE_DUMMY"]
)
