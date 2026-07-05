require "rails_helper"

RSpec.describe PingJob, type: :job do
  let(:client) { double("TelegramClient") }  # rubocop:disable RSpec/VerifiedDoubles — TelegramClient delegates via method_missing

  before do
    allow(TelegramClient).to receive(:from_env).and_return(client)
    allow(client).to receive(:send_message)
  end

  it "sends a delayed pong message to the chat" do
    described_class.perform_now(555, 1)
    expect(client).to have_received(:send_message).with(
      chat_id: 555,
      text: "🏓 Pong! (delayed 1 minute)"
    )
  end

  it "uses plural minutes when minutes > 1" do
    described_class.perform_now(555, 3)
    expect(client).to have_received(:send_message).with(
      chat_id: 555,
      text: "🏓 Pong! (delayed 3 minutes)"
    )
  end

  it "is enqueued with the correct queue" do
    expect(described_class.new.queue_name).to eq("default")
  end
end
