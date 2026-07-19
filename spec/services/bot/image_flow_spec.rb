require "rails_helper"

# Covers the image-capture flows in the dispatcher (G4, plan §6.6).
RSpec.describe Bot::Dispatcher, "image attachments (G4)" do
  let(:client) { double("TelegramClient") } # rubocop:disable RSpec/VerifiedDoubles
  let(:user) { create(:user, telegram_chat_id: 111) }
  let(:dispatcher) { described_class.new(client: client) }

  before do
    allow(User).to receive(:find_or_create_from_update!).and_return(user)
    allow(client).to receive(:send_message)
    allow(client).to receive(:edit_message_text)
    allow(client).to receive(:answer_callback_query)
    allow(client).to receive(:send_photo)
    Rails.cache.clear
  end

  def update(text: nil, callback_data: nil, callback_query_id: nil, photo_file_id: nil, caption: nil,
             chat_id: 111, from_id: 111, message_id: 42)
    Bot::UpdateParser::ParsedUpdate.new(
      chat_id: chat_id, from_id: from_id, first_name: "Tester", language_code: "en",
      text: text, callback_data: callback_data, callback_query_id: callback_query_id, message_id: message_id,
      photo_file_id: photo_file_id, caption: caption
    )
  end

  describe "photo with a caption" do
    it "asks to confirm adding it as a quote with the image" do
      dispatcher.dispatch(update(photo_file_id: "FID", caption: "A framed quote"))
      expect(client).to have_received(:send_message).with(
        hash_including(
          text: a_string_including("with the image"),
          reply_markup: hash_including(inline_keyboard: [ array_including(
            hash_including(callback_data: a_string_starting_with("pc:yes:")),
            hash_including(callback_data: a_string_starting_with("pc:no:"))
          ) ])
        )
      )
    end

    it "creates the quote with the photo and enqueues the attach job on confirm" do
      dispatcher.dispatch(update(photo_file_id: "FID", caption: "A framed quote"))
      # Derive the token from the sent callback_data instead of poking cache internals.
      cb = nil
      expect(client).to have_received(:send_message) do |args|
        cb = args[:reply_markup][:inline_keyboard].flatten.map { |b| b[:callback_data] }.find { |d| d.start_with?("pc:yes:") }
      end

      expect {
        dispatcher.dispatch(update(callback_data: cb, callback_query_id: "c1"))
      }.to change { user.quotes.count }.by(1).and have_enqueued_job(AttachQuoteImageJob)

      quote = user.quotes.last
      expect(quote).to have_attributes(content: "A framed quote", photo_file_id: "FID")
    end

    it "dismisses on the No button without creating a quote" do
      dispatcher.dispatch(update(photo_file_id: "FID", caption: "A framed quote"))
      cb = nil
      expect(client).to have_received(:send_message) do |args|
        cb = args[:reply_markup][:inline_keyboard].flatten.map { |b| b[:callback_data] }.find { |d| d.start_with?("pc:no:") }
      end
      expect {
        dispatcher.dispatch(update(callback_data: cb, callback_query_id: "c1"))
      }.not_to change { user.quotes.count }
      expect(client).to have_received(:answer_callback_query).with(hash_including(text: a_string_including("Dismissed")))
    end

    it "rejects a confirmation tapped by a different user (ownership)" do
      dispatcher.dispatch(update(photo_file_id: "FID", caption: "A framed quote", from_id: 111))
      cb = nil
      expect(client).to have_received(:send_message) do |args|
        cb = args[:reply_markup][:inline_keyboard].flatten.map { |b| b[:callback_data] }.find { |d| d.start_with?("pc:yes:") }
      end
      expect {
        dispatcher.dispatch(update(callback_data: cb, callback_query_id: "c1", from_id: 999))
      }.not_to change { user.quotes.count }
    end
  end

  describe "photo with no caption" do
    it "stashes the image and asks for the quote text" do
      dispatcher.dispatch(update(photo_file_id: "FID"))
      expect(user.reload.state).to eq("awaiting_quote_text_for_photo")
      expect(client).to have_received(:send_message).with(hash_including(text: a_string_including("quote text")))
    end

    it "creates the quote from the next text message with the photo attached" do
      dispatcher.dispatch(update(photo_file_id: "FID"))
      expect {
        dispatcher.dispatch(update(text: "The words for that image"))
      }.to change { user.quotes.count }.by(1).and have_enqueued_job(AttachQuoteImageJob)
      quote = user.quotes.last
      expect(quote).to have_attributes(content: "The words for that image", photo_file_id: "FID")
      expect(user.reload.state).to be_nil
    end

    it "reports expiry if the stashed image is gone" do
      user.update!(state: "awaiting_quote_text_for_photo")
      dispatcher.dispatch(update(text: "words with no cached photo"))
      expect(client).to have_received(:send_message).with(hash_including(text: a_string_including("expired")))
    end
  end

  describe "attaching an image to an existing quote (q:img)" do
    let!(:quote) { create(:quote, user: user, content: "An existing quote here") }

    it "puts the user into awaiting_image_for_quote and asks for a photo" do
      dispatcher.dispatch(update(callback_data: "q:img:#{quote.id}", callback_query_id: "c1"))
      expect(user.reload.state).to eq("awaiting_image_for_quote")
      expect(client).to have_received(:send_message).with(hash_including(text: a_string_including("photo")))
    end

    it "attaches the next photo to that quote and enqueues the attach job" do
      dispatcher.dispatch(update(callback_data: "q:img:#{quote.id}", callback_query_id: "c1"))
      expect {
        dispatcher.dispatch(update(photo_file_id: "NEWFID"))
      }.to have_enqueued_job(AttachQuoteImageJob)
      expect(quote.reload.photo_file_id).to eq("NEWFID")
      expect(user.reload.state).to be_nil
    end

    it "reports if the target quote vanished before the photo arrived" do
      dispatcher.dispatch(update(callback_data: "q:img:#{quote.id}", callback_query_id: "c1"))
      quote.destroy
      dispatcher.dispatch(update(photo_file_id: "NEWFID"))
      expect(client).to have_received(:send_message).with(hash_including(text: a_string_including("no longer here")))
    end

    it "ignores q:img for another user's quote" do
      other = create(:user, telegram_chat_id: 222)
      other_quote = create(:quote, user: other)
      dispatcher.dispatch(update(callback_data: "q:img:#{other_quote.id}", callback_query_id: "c1"))
      expect(user.reload.state).to be_nil
    end

    it "supports the /addimage <id> typed fallback" do
      dispatcher.dispatch(update(text: "/addimage #{quote.id}"))
      expect(user.reload.state).to eq("awaiting_image_for_quote")
    end

    it "reports a bad /addimage id without wedging state" do
      dispatcher.dispatch(update(text: "/addimage 999999"))
      expect(user.reload.state).to be_nil
      expect(client).to have_received(:send_message).with(hash_including(text: a_string_including("Couldn't find")))
    end

    it "abandons awaiting_image_for_quote if the user sends text instead of a photo" do
      dispatcher.dispatch(update(callback_data: "q:img:#{quote.id}", callback_query_id: "c1"))
      dispatcher.dispatch(update(text: "changed my mind, here's a new quote"))
      expect(user.reload.state).to be_nil
    end
  end

  describe "'Another' when the source card was a photo but the next pick is text" do
    it "falls back to a fresh message when editing a media card fails" do
      create(:quote, user: user, content: "A text-only quote here", photo_file_id: nil)
      # Simulate Telegram rejecting an edit of a media message.
      allow(client).to receive(:edit_message_text).and_raise(TelegramClient::Error, "no text in the message to edit")
      dispatcher.dispatch(update(callback_data: "q:rand:0", callback_query_id: "c1"))
      expect(client).to have_received(:send_message).with(hash_including(text: a_string_including("A text-only quote here")))
    end
  end

  describe "delivering a photo quote on /quote" do
    it "sends a photo, not a text message" do
      create(:quote, user: user, content: "A framed quote", photo_file_id: "FID")
      dispatcher.dispatch(update(text: "/quote"))
      expect(client).to have_received(:send_photo).with(hash_including(photo: "FID"))
    end
  end
end
