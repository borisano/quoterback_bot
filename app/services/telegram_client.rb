require "telegram/bot"

# Thin facade over Telegram::Bot::Api. Delegates all Bot API methods to the gem
# and maps errors to typed exceptions so callers can branch on 403 (user blocked)
# vs other failures.
class TelegramClient
  class Error < StandardError; end
  class Forbidden < Error; end  # 403 — bot was blocked by the user

  attr_reader :token

  def self.from_env
    new(token: ENV.fetch("TELEGRAM_BOT_TOKEN"))
  end

  def initialize(token:)
    @token = token
    @api = Telegram::Bot::Api.new(token)
  end

  # Delegate any Bot API method (send_message, answer_callback_query, set_webhook…)
  # directly to the underlying gem API object.
  def method_missing(name, *args, **kwargs, &block)
    params = kwargs.any? ? kwargs : (args.first || {})
    params = serialize_reply_markup(params)
    @api.public_send(name, params)
  rescue Telegram::Bot::Exceptions::ResponseError => e
    raise Forbidden, e.message if e.response.status == 403
    # Editing a message to identical content is a no-op error (e.g. re-tapping
    # the current page, or "Another" re-picking the same quote). Swallow it so
    # callers don't abort mid-handler (C6).
    return nil if e.message.include?("message is not modified")

    raise Error, e.message
  end

  def respond_to_missing?(name, include_private = false)
    @api.respond_to?(name) || super
  end

  private

  # telegram-bot-ruby only auto-serializes reply_markup for its own typed objects.
  # Plain Ruby hashes must be JSON-encoded explicitly or Faraday form-encodes them
  # and Telegram silently drops the keyboard.
  def serialize_reply_markup(params)
    return params unless params[:reply_markup].is_a?(Hash)

    params.merge(reply_markup: params[:reply_markup].to_json)
  end
end
