require "rails_helper"

RSpec.describe Bot::Dispatcher do
  let(:client) { double("TelegramClient") }  # rubocop:disable RSpec/VerifiedDoubles — TelegramClient delegates via method_missing
  let(:dispatcher) { described_class.new(client: client) }

  def parsed_update(text:, chat_id: 111)
    Bot::UpdateParser::ParsedUpdate.new(
      chat_id: chat_id,
      from_id: 111,
      first_name: "Tester",
      language_code: "en",
      text: text,
      callback_data: nil,
      callback_query_id: nil,
      message_id: nil
    )
  end

  describe "#dispatch" do
    context "with /ping command" do
      it "sends 'Pong!' back to the user" do
        allow(client).to receive(:send_message)
        dispatcher.dispatch(parsed_update(text: "/ping"))
        expect(client).to have_received(:send_message).with(
          chat_id: 111,
          text: "🏓 Pong!"
        )
      end
    end

    context "with /start command" do
      it "sends a welcome message" do
        allow(client).to receive(:send_message)
        dispatcher.dispatch(parsed_update(text: "/start"))
        expect(client).to have_received(:send_message).with(
          hash_including(chat_id: 111, text: a_string_including("Welcome"))
        )
      end
    end

    context "with nil update" do
      it "does nothing and does not raise" do
        expect { dispatcher.dispatch(nil) }.not_to raise_error
      end
    end

    context "with 'ping me in N minutes' text" do
      before { allow(client).to receive(:send_message) }

      it "enqueues a PingJob with the correct chat_id and minutes" do
        expect {
          dispatcher.dispatch(parsed_update(text: "ping me in 2 minutes"))
        }.to have_enqueued_job(PingJob).with(111, 2)
      end

      it "acknowledges the scheduling request" do
        dispatcher.dispatch(parsed_update(text: "ping me in 5 min"))
        expect(client).to have_received(:send_message).with(
          chat_id: 111,
          text: a_string_including("5 minutes")
        )
      end

      it "defaults to 1 minute when no number is given" do
        expect {
          dispatcher.dispatch(parsed_update(text: "ping me in a min"))
        }.to have_enqueued_job(PingJob).with(111, 1)
      end
    end
  end
end
