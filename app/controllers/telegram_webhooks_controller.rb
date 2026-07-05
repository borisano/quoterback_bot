class TelegramWebhooksController < ActionController::API
  before_action :verify_secret_token

  # Receives Telegram updates in production (webhook mode) and dispatches them.
  def create
    parsed = Bot::UpdateParser.parse(params.to_unsafe_h.deep_symbolize_keys)
    Bot::Dispatcher.new.dispatch(parsed) if parsed
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
