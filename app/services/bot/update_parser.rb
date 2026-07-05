module Bot
  # Normalizes a raw Telegram update into a consistent struct regardless of
  # whether it came from the long-polling runner (telegram-bot-ruby objects) or
  # the webhook controller (ActionController::Parameters / plain Hash).
  class UpdateParser
    ParsedUpdate = Data.define(
      :chat_id, :from_id, :first_name, :language_code, :text, :callback_data, :callback_query_id, :message_id
    )

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
        message_id:        get(msg, :message_id)
      )
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
