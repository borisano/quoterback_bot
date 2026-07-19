require "telegram/bot"
require "net/http"

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

  # Timeouts so a hung file server can never block the dispatcher thread forever.
  DOWNLOAD_OPEN_TIMEOUT = 10
  DOWNLOAD_READ_TIMEOUT = 30

  # Downloads a file's raw contents by file_id: getFile → build the file URL →
  # fetch it. Returns a UTF-8 String (invalid bytes scrubbed) or nil if Telegram
  # returned no file_path. The body is streamed and aborted once it exceeds
  # `max_bytes` (when given), so an oversized or metadata-less upload can't be
  # read wholesale into memory. Network/timeout failures are mapped to Error so
  # callers only need to rescue TelegramClient::Error.
  # ⚠️ The download URL embeds the bot token — it is NEVER logged or raised.
  def download_file(file_id, max_bytes: nil)
    resp = get_file(file_id: file_id)
    file_path = extract_file_path(resp)
    return nil if file_path.nil? || file_path.to_s.empty?

    uri = URI.parse("https://api.telegram.org/file/bot#{token}/#{file_path}")
    fetch_body(uri, max_bytes)
  rescue Telegram::Bot::Exceptions::ResponseError => e
    raise Forbidden, e.message if e.response.status == 403
    raise Error, e.message
  rescue URI::InvalidURIError
    # The offending string is the token-bearing URL — never surface it (§17).
    raise Error, "file download failed (bad path)"
  end

  private

  def fetch_body(uri, max_bytes)
    body = +""
    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
      open_timeout: DOWNLOAD_OPEN_TIMEOUT, read_timeout: DOWNLOAD_READ_TIMEOUT) do |http|
      http.request(Net::HTTP::Get.new(uri)) do |response|
        # Don't interpolate the URI into any message — it carries the bot token.
        raise Error, "file download failed (#{response.code})" unless response.is_a?(Net::HTTPSuccess)

        response.read_body do |chunk|
          body << chunk
          raise Error, "file exceeds #{max_bytes} bytes" if max_bytes && body.bytesize > max_bytes
        end
      end
    end
    body.encode("UTF-8", invalid: :replace, undef: :replace)
  rescue SocketError, IOError, SystemCallError, Timeout::Error => e
    raise Error, "file download failed: #{e.class}"
  end

  # getFile responses vary by gem version (typed object vs Hash); pull file_path
  # out of whichever shape we got.
  def extract_file_path(resp)
    return resp.file_path if resp.respond_to?(:file_path)

    result =
      if resp.respond_to?(:result) then resp.result
      elsif resp.is_a?(Hash) then resp["result"] || resp[:result]
      end
    return nil if result.nil?
    return result.file_path if result.respond_to?(:file_path)

    result["file_path"] || result[:file_path] if result.respond_to?(:[])
  end

  # telegram-bot-ruby only auto-serializes reply_markup for its own typed objects.
  # Plain Ruby hashes must be JSON-encoded explicitly or Faraday form-encodes them
  # and Telegram silently drops the keyboard.
  def serialize_reply_markup(params)
    return params unless params[:reply_markup].is_a?(Hash)

    params.merge(reply_markup: params[:reply_markup].to_json)
  end
end
