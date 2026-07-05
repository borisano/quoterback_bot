module Bot
  # Routes a normalized ParsedUpdate to the appropriate handler.
  # Keep this class thin — delegate heavy work to service objects and jobs.
  class Dispatcher
    def initialize(client: TelegramClient.from_env)
      @client = client
    end

    def dispatch(update)
      return if update.nil?

      if update.callback_data
        handle_callback(update)
      elsif update.text.present?
        handle_text(update)
      end
    rescue StandardError => e
      Rails.logger.error("[Bot::Dispatcher] Error: #{e.class} — #{e.message}")
    end

    private

    attr_reader :client

    def handle_text(update)
      text = update.text.strip
      command = text.split(/\s+/, 2).first.downcase

      case command
      when "/start"
        handle_start(update)
      when "/ping"
        handle_ping(update)
      else
        handle_schedule_ping(update) if text.match?(/\bing\b.*\d+\s*min/i) || text.match?(/ping me in/i)
      end
    end

    def handle_callback(update)
      # Placeholder — callback routing added per-feature
    end

    def handle_start(update)
      client.send_message(
        chat_id: update.chat_id,
        text: "👋 Welcome to QuoterBack! Use /ping to test the connection."
      )
    end

    def handle_ping(update)
      client.send_message(chat_id: update.chat_id, text: "🏓 Pong!")
    end

    def handle_schedule_ping(update)
      minutes = update.text.match(/(\d+)\s*min/i)&.captures&.first&.to_i
      minutes ||= 1

      PingJob.set(wait: minutes.minutes).perform_later(update.chat_id, minutes)

      client.send_message(
        chat_id: update.chat_id,
        text: "⏱ I'll ping you back in #{minutes} minute#{"s" if minutes != 1}!"
      )
    end
  end
end
