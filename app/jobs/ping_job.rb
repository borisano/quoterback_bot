class PingJob < ApplicationJob
  queue_as :default

  # Sends a delayed "Pong!" message back to the user.
  # Triggered by "ping me in N minutes" text in the dispatcher.
  def perform(chat_id, minutes)
    TelegramClient.from_env.send_message(
      chat_id: chat_id,
      text: "🏓 Pong! (delayed #{minutes} minute#{"s" if minutes != 1})"
    )
  end
end
