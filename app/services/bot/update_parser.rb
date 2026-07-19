module Bot
  # Normalizes a raw Telegram update into a consistent struct regardless of
  # whether it came from the long-polling runner (telegram-bot-ruby objects) or
  # the webhook controller (ActionController::Parameters / plain Hash).
  class UpdateParser
    # `document` is a Hash ({ file_id:, file_name:, file_size:, mime_type: }) when
    # the message carries an uploaded file, else nil. `photo_file_id` is the
    # largest PhotoSize's file_id when the message carries a photo, and `caption`
    # is the photo/document caption. All three default to nil so every existing
    # constructor (and spec) that omits them keeps working.
    ParsedUpdate = Data.define(
      :chat_id, :from_id, :first_name, :language_code, :text, :callback_data, :callback_query_id, :message_id,
      :document, :photo_file_id, :caption
    ) do
      def initialize(document: nil, photo_file_id: nil, caption: nil, **rest)
        super(document: document, photo_file_id: photo_file_id, caption: caption, **rest)
      end
    end

    def self.parse(update)
      new(update).parse
    end

    def initialize(update)
      @u = update
    end

    def parse
      if (cq = get(@u, :callback_query))
        parse_callback(cq)
      elsif (msg = get(@u, :message))
        parse_message(msg)
      end
      # Returns nil for unknown/empty updates — callers must guard against nil.
    end

    private

    def parse_callback(cq)
      msg = get(cq, :message)
      ParsedUpdate.new(
        chat_id:           get(get(msg, :chat), :id),
        from_id:           get(get(cq, :from), :id),
        first_name:        get(get(cq, :from), :first_name),
        language_code:     get(get(cq, :from), :language_code),
        text:              nil,
        callback_data:     get(cq, :data),
        callback_query_id: get(cq, :id)&.to_s,
        message_id:        get(msg, :message_id)
      )
    end

    def parse_message(msg)
      from = get(msg, :from)
      ParsedUpdate.new(
        chat_id:           get(get(msg, :chat), :id),
        from_id:           get(from, :id),
        first_name:        get(from, :first_name),
        language_code:     get(from, :language_code),
        text:              get(msg, :text),
        callback_data:     nil,
        callback_query_id: nil,
        message_id:        get(msg, :message_id),
        document:          parse_document(msg),
        photo_file_id:     parse_photo(msg),
        caption:           get(msg, :caption)
      )
    end

    def parse_document(msg)
      doc = get(msg, :document)
      return nil if doc.nil?

      {
        file_id:   get(doc, :file_id),
        file_name: get(doc, :file_name),
        file_size: get(doc, :file_size),
        mime_type: get(doc, :mime_type)
      }
    end

    # Telegram sends a photo as an array of increasing-resolution PhotoSizes.
    # Always take the largest (plan §6.6) — the first is a tiny thumbnail.
    def parse_photo(msg)
      photos = get(msg, :photo)
      return nil if photos.blank?

      largest = photos.max_by { |p| get(p, :file_size).to_i }
      get(largest, :file_id)
    end

    # Handles telegram-bot-ruby typed objects (respond to method names),
    # plain Symbol-keyed Hashes, and ActionController::Parameters (respond to []).
    def get(obj, key)
      return nil if obj.nil?

      if obj.respond_to?(key)
        obj.public_send(key)
      elsif obj.respond_to?(:[], true)
        obj[key] || obj[key.to_s]
      end
    end
  end
end
