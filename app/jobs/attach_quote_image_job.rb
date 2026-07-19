require "stringio"

# Downloads a quote's Telegram photo and attaches a durable copy to Active
# Storage (S3 in production) — plan §6.6. The Telegram file_id is stored on the
# quote synchronously at capture time, so delivery works immediately by re-sending
# that file_id; this job just adds the durable web-usable copy in the background.
# A failure here is non-fatal: delivery falls back to the file_id.
class AttachQuoteImageJob < ApplicationJob
  queue_as :default

  MAX_BYTES = 20.megabytes # Telegram getFile only serves files up to 20 MB.

  # Transient download failures retry; a permanent failure just leaves the quote
  # with its file_id (delivery still works).
  retry_on TelegramClient::Error, wait: 30.seconds, attempts: 3

  def perform(quote_id)
    quote = Quote.find_by(id: quote_id)
    return unless quote
    return if quote.photo_file_id.blank?
    return if quote.image.attached? # idempotent — already attached

    data = TelegramClient.from_env.download_file(quote.photo_file_id, max_bytes: MAX_BYTES, binary: true)
    return if data.blank?

    quote.image.attach(
      io: StringIO.new(data),
      filename: "quote_#{quote.id}.jpg",
      content_type: "image/jpeg"
    )
  rescue TelegramClient::Forbidden => e
    # Bot blocked; nothing to attach. Don't retry.
    Rails.logger.warn("[AttachQuoteImageJob] forbidden for quote #{quote_id}: #{e.message}")
  end
end
