require "rails_helper"

RSpec.describe Bot::QuoteMessenger do
  let(:client) { double("TelegramClient") } # rubocop:disable RSpec/VerifiedDoubles
  let(:user) { create(:user, telegram_chat_id: 111) }
  let(:markup) { { inline_keyboard: [ [ { text: "🎲", callback_data: "q:rand:0" } ] ] } }

  before do
    allow(client).to receive(:send_message)
    allow(client).to receive(:send_photo)
  end

  def deliver(quote)
    described_class.send_quote(client: client, chat_id: 111, quote: quote, reply_markup: markup)
  end

  context "a text-only quote" do
    let(:quote) { create(:quote, user: user, content: "A short and sweet quote", photo_file_id: nil) }

    it "sends a plain message with the keyboard" do
      deliver(quote)
      expect(client).to have_received(:send_message).with(hash_including(chat_id: 111, reply_markup: markup))
      expect(client).not_to have_received(:send_photo)
    end
  end

  context "a photo quote whose caption fits" do
    let(:quote) { create(:quote, user: user, content: "A framed quote", photo_file_id: "FID") }

    it "sends the photo with the full text as caption and the keyboard" do
      deliver(quote)
      expect(client).to have_received(:send_photo).with(
        hash_including(chat_id: 111, photo: "FID", caption: a_string_including("A framed quote"), reply_markup: markup)
      )
      expect(client).not_to have_received(:send_message)
    end
  end

  context "a photo quote whose text exceeds the 1024-char caption cap" do
    # content(1000) + author(100) + source(200) formats to > 1024 chars.
    let(:quote) do
      create(:quote, user: user, content: "c" * 1000, author: "a" * 100, source: "s" * 200, photo_file_id: "FID")
    end

    it "sends the photo with a truncated caption, then the full text with the keyboard" do
      deliver(quote)
      expect(client).to have_received(:send_photo).with(
        hash_including(photo: "FID", reply_markup: nil)
      )
      expect(client).to have_received(:send_message).with(
        hash_including(text: a_string_including("c" * 1000), reply_markup: markup)
      )
    end
  end

  context "when send_photo fails (stale file_id) and there is no durable copy" do
    let(:quote) { create(:quote, user: user, content: "A framed quote", photo_file_id: "STALE") }

    before { allow(client).to receive(:send_photo).and_raise(TelegramClient::Error, "wrong file_id") }

    it "falls back to sending the text, so delivery never hard-fails" do
      expect { deliver(quote) }.not_to raise_error
      expect(client).to have_received(:send_message).with(hash_including(text: a_string_including("A framed quote")))
    end
  end

  context "when send_photo fails but a durable Active Storage copy exists" do
    let(:quote) do
      q = create(:quote, user: user, content: "A framed quote", photo_file_id: "STALE")
      q.image.attach(io: StringIO.new("\xFF\xD8\xFFfake-jpeg".b), filename: "q.jpg", content_type: "image/jpeg")
      q
    end

    it "re-uploads the stored image as a multipart file and captures the fresh file_id" do
      # First send_photo (by file_id) fails; the multipart re-upload succeeds.
      call = 0
      allow(client).to receive(:send_photo) do |args|
        call += 1
        raise TelegramClient::Error, "wrong file_id" if call == 1

        expect(args[:photo]).to be_a(Faraday::Multipart::FilePart)
        { "result" => { "photo" => [ { "file_id" => "FRESH", "file_size" => 500 } ] } }
      end

      deliver(quote)
      expect(quote.reload.photo_file_id).to eq("FRESH")
    end

    it "still delivers as text if the re-upload itself fails" do
      allow(client).to receive(:send_photo).and_raise(TelegramClient::Error, "boom")
      allow(Rollbar).to receive(:error)
      expect { deliver(quote) }.not_to raise_error
      expect(client).to have_received(:send_message).with(hash_including(text: a_string_including("A framed quote")))
    end
  end
end
