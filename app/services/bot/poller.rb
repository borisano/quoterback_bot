require "telegram/bot"

module Bot
  # Long-polling loop for development. Parses every update through UpdateParser
  # and forwards to the Dispatcher. Production uses the webhook controller instead.
  class Poller
    def self.from_env
      new(
        bot: Telegram::Bot::Client.new(ENV.fetch("TELEGRAM_BOT_TOKEN")),
        dispatcher: Dispatcher.new
      )
    end

    def initialize(bot:, dispatcher: Dispatcher.new)
      @bot = bot
      @dispatcher = dispatcher
    end

    def run
      @bot.listen do |update|
        raw = typed_update_to_hash(update)
        parsed = UpdateParser.parse(raw)
        next unless parsed

        @dispatcher.dispatch(parsed)
      rescue StandardError => e
        Rails.logger.error("[Bot::Poller] error: #{e.class}: #{e.message}")
        Rollbar.error(e)
      end
    rescue SignalException, Interrupt
      # Graceful shutdown — foreman sends SIGTERM, Ctrl-C sends SIGINT.
      Rails.logger.info("[Bot::Poller] shutting down")
    end

    private

    def typed_update_to_hash(update)
      if update.respond_to?(:data) && update.respond_to?(:message)
        { callback_query: update }
      elsif update.respond_to?(:chat)
        { message: update }
      else
        {}
      end
    end
  end
end
