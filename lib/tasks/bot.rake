namespace :bot do
  desc "Run the Telegram bot in long-polling mode (development)"
  task poll: :environment do
    Rails.logger.info("[bot:poll] starting long-polling…")
    puts "🤖 QuoterBack bot polling for updates (Ctrl-C to stop)…"
    Bot::Poller.from_env.run
  end

  desc "Register the webhook URL with Telegram (production). Set WEBHOOK_URL and optionally TELEGRAM_WEBHOOK_SECRET."
  task set_webhook: :environment do
    token  = ENV.fetch("TELEGRAM_BOT_TOKEN")
    url    = ENV.fetch("WEBHOOK_URL") { abort "Set WEBHOOK_URL=https://yourhost.com/telegram/webhook" }
    secret = ENV["TELEGRAM_WEBHOOK_SECRET"]

    client = Telegram::Bot::Client.new(token)
    params = { url: url }
    params[:secret_token] = secret if secret.present?

    result = client.api.set_webhook(**params)
    if result["ok"]
      puts "✅ Webhook registered: #{url}"
    else
      puts "❌ Failed: #{result.inspect}"
    end
  end

  desc "Delete the currently registered webhook (reverts to long-polling)"
  task delete_webhook: :environment do
    token  = ENV.fetch("TELEGRAM_BOT_TOKEN")
    client = Telegram::Bot::Client.new(token)
    result = client.api.delete_webhook
    puts result["ok"] ? "✅ Webhook deleted." : "❌ Failed: #{result.inspect}"
  end

  desc "Register bot commands with Telegram (native command menu)"
  task set_commands: :environment do
    token  = ENV.fetch("TELEGRAM_BOT_TOKEN")
    client = Telegram::Bot::Client.new(token)
    result = client.api.set_my_commands(
      commands: [
        { command: "start",  description: "Start the bot" },
        { command: "ping",   description: "Test the connection" },
        { command: "add",    description: "Add a quote" },
        { command: "quote",  description: "Get a random quote" },
        { command: "list",   description: "Browse your quotes" },
        { command: "delete", description: "Delete a quote" },
        { command: "settings", description: "Your settings" },
        { command: "schedule", description: "Set daily delivery time" },
        { command: "cancel",   description: "Turn off daily delivery" },
        { command: "settimezone", description: "Set your timezone" }
      ].to_json
    )
    puts result["ok"] ? "✅ Commands registered." : "❌ Failed: #{result.inspect}"
  end

  desc "Manually send a ping to a user (usage: rails 'bot:ping_now[chat_id]')"
  task :ping_now, [:chat_id] => :environment do |_, args|
    chat_id = args[:chat_id]&.to_i
    abort "Usage: rails 'bot:ping_now[TELEGRAM_CHAT_ID]'" unless chat_id

    TelegramClient.from_env.send_message(chat_id: chat_id, text: "🏓 Pong! (manual ping)")
    puts "✅ Ping sent to chat_id #{chat_id}"
  end
end
