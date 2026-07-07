require "rails_helper"

RSpec.describe TelegramClient do
  # The gem's Api implements every Bot API call via method_missing, so a verified
  # double can't be used here.
  let(:api) { double("Telegram::Bot::Api") } # rubocop:disable RSpec/VerifiedDoubles
  subject(:client) { described_class.new(token: "TEST_TOKEN") }

  before { allow(Telegram::Bot::Api).to receive(:new).and_return(api) }

  def response_error(status, description)
    body = { ok: false, error_code: status, description: description }.to_json
    response = double("Faraday::Response", status: status, body: body) # rubocop:disable RSpec/VerifiedDoubles
    Telegram::Bot::Exceptions::ResponseError.new(response: response)
  end

  describe "reply_markup serialization" do
    it "JSON-encodes a Hash reply_markup before delegating to the gem" do
      allow(api).to receive(:send_message)
      client.send_message(chat_id: 1, text: "hi", reply_markup: { inline_keyboard: [] })
      expect(api).to have_received(:send_message).with(
        hash_including(reply_markup: an_instance_of(String))
      )
    end

    it "produces valid JSON for the encoded keyboard" do
      captured = nil
      allow(api).to receive(:send_message) { |params| captured = params }
      client.send_message(chat_id: 1, text: "hi", reply_markup: { inline_keyboard: [ [ { text: "A" } ] ] })
      expect(JSON.parse(captured[:reply_markup])).to eq("inline_keyboard" => [ [ { "text" => "A" } ] ])
    end

    it "leaves calls without reply_markup untouched" do
      allow(api).to receive(:send_message)
      client.send_message(chat_id: 1, text: "hi")
      expect(api).to have_received(:send_message).with(chat_id: 1, text: "hi")
    end
  end

  describe "error mapping" do
    it "raises Forbidden on 403 (bot blocked)" do
      allow(api).to receive(:send_message).and_raise(response_error(403, "Forbidden: bot was blocked by the user"))
      expect { client.send_message(chat_id: 1, text: "hi") }.to raise_error(TelegramClient::Forbidden)
    end

    it "raises Error on other 4xx/5xx" do
      allow(api).to receive(:send_message).and_raise(response_error(400, "Bad Request: chat not found"))
      expect { client.send_message(chat_id: 1, text: "hi") }.to raise_error(TelegramClient::Error)
    end
  end

  describe "'message is not modified' handling (C6)" do
    before do
      allow(api).to receive(:edit_message_text)
        .and_raise(response_error(400, "Bad Request: message is not modified"))
    end

    it "swallows the error and returns nil instead of raising" do
      expect {
        expect(client.edit_message_text(chat_id: 1, message_id: 2, text: "same")).to be_nil
      }.not_to raise_error
    end

    it "does not raise Forbidden for this case" do
      expect {
        client.edit_message_text(chat_id: 1, message_id: 2, text: "same")
      }.not_to raise_error(TelegramClient::Forbidden)
    end
  end
end
