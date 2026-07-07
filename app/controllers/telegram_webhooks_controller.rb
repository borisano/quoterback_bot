class TelegramWebhooksController < ActionController::API
  before_action :verify_secret_token

  # Receives Telegram updates in production (webhook mode) and dispatches them.
  # Always returns 200 — a 5xx makes Telegram retry the same update repeatedly
  # (duplicate quotes/messages). Errors are logged/reported, never surfaced (M15).
  def create
    parsed = Bot::UpdateParser.parse(params.to_unsafe_h.deep_symbolize_keys)
    Bot::Dispatcher.new.dispatch(parsed) if parsed
    head :ok
  rescue StandardError => e
    Rails.logger.error("[TelegramWebhooks] #{e.class}: #{e.message}")
    Rollbar.error(e)
    head :ok
  end

  private

  def verify_secret_token
    secret = ENV["TELEGRAM_WEBHOOK_SECRET"]
    return if secret.blank?

    provided = request.headers["X-Telegram-Bot-Api-Secret-Token"]
    head :unauthorized unless ActiveSupport::SecurityUtils.secure_compare(secret, provided.to_s)
  end
end
