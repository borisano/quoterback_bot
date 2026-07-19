require "faraday"
require "faraday/multipart"

module Bot
  # Single place that sends a quote to a chat, handling the photo-vs-text split and
  # the two failure modes the plan calls out (§6.6):
  #   1. Caption cap: a photo caption is limited to 1024 chars (not 4096). If the
  #      formatted quote is longer, send the photo with a truncated caption then the
  #      full text as a follow-up message (the follow-up carries the action row).
  #   2. Stale file_id: a stored file_id can become invalid. If send_photo fails,
  #      re-upload the durable Active Storage copy as a multipart file (capturing the
  #      fresh file_id), or — if no durable copy exists — fall back to text-only.
  # Delivery must never hard-fail because an image went missing.
  class QuoteMessenger
    CAPTION_LIMIT = 1024

    def self.send_quote(client:, chat_id:, quote:, reply_markup: nil)
      new(client: client, chat_id: chat_id, quote: quote, reply_markup: reply_markup).send_quote
    end

    def initialize(client:, chat_id:, quote:, reply_markup: nil)
      @client = client
      @chat_id = chat_id
      @quote = quote
      @reply_markup = reply_markup
    end

    def send_quote
      return send_text unless @quote.photo_file_id.present?

      send_photo_quote
    end

    private

    attr_reader :client, :chat_id, :quote, :reply_markup

    def presenter
      @presenter ||= QuotePresenter.new(quote)
    end

    def full_text
      @full_text ||= presenter.message_text
    end

    def caption_fits?
      full_text.length <= CAPTION_LIMIT
    end

    def send_text(text: full_text, markup: reply_markup)
      client.send_message(chat_id: chat_id, text: text, reply_markup: markup)
    end

    def send_photo_quote
      if caption_fits?
        send_photo(photo: quote.photo_file_id, caption: full_text, markup: reply_markup)
      else
        # Photo carries a truncated caption; the full text follows with the keyboard.
        send_photo(photo: quote.photo_file_id, caption: presenter.caption_text, markup: nil)
        send_text
      end
    rescue TelegramClient::Forbidden
      # The user blocked the bot — not a stale file_id. Let it propagate so the
      # caller (DeliverQuoteJob) can deactivate them; don't waste an S3 re-upload
      # or fire a spurious image-error alert.
      raise
    rescue TelegramClient::Error
      recover_from_bad_file_id
    end

    def send_photo(photo:, caption:, markup:)
      client.send_photo(chat_id: chat_id, photo: photo, caption: caption, reply_markup: markup)
    end

    # send_photo(file_id) failed — the id is likely stale. Prefer re-uploading the
    # durable copy; otherwise degrade to text so the user still gets the quote.
    def recover_from_bad_file_id
      return send_text unless quote.image.attached?

      reupload_from_storage
    rescue StandardError => e
      Rails.logger.error("[QuoteMessenger] image re-upload failed for quote #{quote.id}: #{e.class}")
      Rollbar.error(e, quote_id: quote.id)
      send_text
    end

    def reupload_from_storage
      caption = caption_fits? ? full_text : presenter.caption_text
      markup  = caption_fits? ? reply_markup : nil

      quote.image.blob.open do |file|
        part = Faraday::Multipart::FilePart.new(file, quote.image.content_type || "image/jpeg")
        response = send_photo(photo: part, caption: caption, markup: markup)
        # Cache the fresh file_id so future sends are cheap again.
        new_id = largest_photo_file_id(response)
        quote.update!(photo_file_id: new_id) if new_id.present?
      end

      send_text(markup: reply_markup) unless caption_fits?
    end

    # Pulls the largest PhotoSize's file_id out of a send_photo response (typed
    # object or Hash shape), or nil if it can't be found.
    def largest_photo_file_id(response)
      photos = dig_photos(response)
      return nil if photos.blank?

      largest = photos.max_by { |p| fetch(p, :file_size).to_i }
      fetch(largest, :file_id)
    end

    def dig_photos(response)
      result =
        if response.respond_to?(:result) then response.result
        elsif response.respond_to?(:photo) then response
        elsif response.is_a?(Hash) then response["result"] || response[:result]
        end
      fetch(result, :photo)
    end

    def fetch(obj, key)
      return nil if obj.nil?
      return obj.public_send(key) if obj.respond_to?(key)

      obj[key] || obj[key.to_s] if obj.respond_to?(:[])
    end
  end
end
