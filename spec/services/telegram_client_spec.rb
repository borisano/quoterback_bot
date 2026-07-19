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

  describe "#download_file" do
    let(:file_path) { "documents/file_7.txt" }
    let(:file_url) { "https://api.telegram.org/file/botTEST_TOKEN/#{file_path}" }

    before do
      allow(api).to receive(:get_file).and_return(double(result: double(file_path: file_path))) # rubocop:disable RSpec/VerifiedDoubles
    end

    it "fetches the file contents via getFile then the file URL" do
      stub_request(:get, file_url).to_return(status: 200, body: "line one\nline two")
      expect(client.download_file("FID")).to eq("line one\nline two")
    end

    it "handles a Hash-shaped getFile response" do
      allow(api).to receive(:get_file).and_return("result" => { "file_path" => file_path })
      stub_request(:get, file_url).to_return(status: 200, body: "hash shaped ok")
      expect(client.download_file("FID")).to eq("hash shaped ok")
    end

    it "handles a getFile response whose object exposes file_path directly" do
      allow(api).to receive(:get_file).and_return(double(file_path: file_path)) # rubocop:disable RSpec/VerifiedDoubles
      stub_request(:get, file_url).to_return(status: 200, body: "direct ok")
      expect(client.download_file("FID")).to eq("direct ok")
    end

    it "returns nil when Telegram reports no file_path" do
      allow(api).to receive(:get_file).and_return(double(result: double(file_path: nil))) # rubocop:disable RSpec/VerifiedDoubles
      expect(client.download_file("FID")).to be_nil
    end

    it "raises Error when the download responds non-2xx" do
      stub_request(:get, file_url).to_return(status: 404, body: "")
      expect { client.download_file("FID") }.to raise_error(TelegramClient::Error)
    end

    it "raises Forbidden when getFile 403s" do
      allow(api).to receive(:get_file).and_raise(response_error(403, "Forbidden: bot was blocked"))
      expect { client.download_file("FID") }.to raise_error(TelegramClient::Forbidden)
    end

    it "aborts and raises Error when the body exceeds max_bytes" do
      stub_request(:get, file_url).to_return(status: 200, body: "x" * 1000)
      expect { client.download_file("FID", max_bytes: 100) }.to raise_error(TelegramClient::Error)
    end

    it "maps a network failure to Error (never leaks the token URL)" do
      stub_request(:get, file_url).to_raise(SocketError.new("getaddrinfo"))
      expect { client.download_file("FID") }.to raise_error(TelegramClient::Error) do |e|
        expect(e.message).not_to include("TEST_TOKEN")
      end
    end

    it "scrubs invalid UTF-8 bytes in the body" do
      stub_request(:get, file_url).to_return(status: 200, body: "bad\xFFbyte".b)
      expect { client.download_file("FID") }.not_to raise_error
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
