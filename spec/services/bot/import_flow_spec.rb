require "rails_helper"

# Covers the /import command and the document-upload handler (G5, plan §6.4).
RSpec.describe Bot::Dispatcher, "import from a text file (G5)" do
  let(:client) { double("TelegramClient") } # rubocop:disable RSpec/VerifiedDoubles
  let(:user) { create(:user, telegram_chat_id: 111) }
  let(:dispatcher) { described_class.new(client: client) }

  before do
    allow(User).to receive(:find_or_create_from_update!).and_return(user)
    allow(client).to receive(:send_message)
    allow(client).to receive(:edit_message_text)
    allow(client).to receive(:answer_callback_query)
  end

  def update(text: nil, callback_data: nil, callback_query_id: nil, document: nil, chat_id: 111, from_id: 111, message_id: 42)
    Bot::UpdateParser::ParsedUpdate.new(
      chat_id: chat_id, from_id: from_id, first_name: "Tester", language_code: "en",
      text: text, callback_data: callback_data, callback_query_id: callback_query_id,
      message_id: message_id, document: document
    )
  end

  def doc(file_name: "quotes.txt", mime_type: "text/plain", file_size: 100, file_id: "FID")
    { file_id: file_id, file_name: file_name, file_size: file_size, mime_type: mime_type }
  end

  describe "/import" do
    it "puts the user into the awaiting_import_file state and prompts for a file" do
      dispatcher.dispatch(update(text: "/import"))
      expect(user.reload.state).to eq("awaiting_import_file")
      expect(client).to have_received(:send_message).with(hash_including(text: a_string_including(".txt")))
    end

    it "is reachable from the settings Import button (set:import)" do
      dispatcher.dispatch(update(callback_data: "set:import", callback_query_id: "c1"))
      expect(user.reload.state).to eq("awaiting_import_file")
    end
  end

  describe "receiving a document" do
    it "downloads a .txt file and imports its lines" do
      allow(client).to receive(:download_file).with("FID").and_return("First good quote line\nSecond good quote line")
      expect {
        dispatcher.dispatch(update(document: doc))
      }.to change { user.quotes.count }.by(2)
      expect(client).to have_received(:send_message).with(hash_including(text: a_string_including("Imported 2")))
    end

    it "clears the awaiting_import_file state after a successful import" do
      user.update!(state: "awaiting_import_file")
      allow(client).to receive(:download_file).and_return("A single good quote line")
      dispatcher.dispatch(update(document: doc))
      expect(user.reload.state).to be_nil
    end

    it "reports skipped lines" do
      create(:quote, user: user, content: "Already saved quote line")
      allow(client).to receive(:download_file).and_return("Already saved quote line\nA fresh new quote line")
      dispatcher.dispatch(update(document: doc))
      expect(client).to have_received(:send_message).with(hash_including(text: a_string_including("skipped 1")))
    end

    it "reports when nothing new was added" do
      create(:quote, user: user, content: "Already saved quote line")
      allow(client).to receive(:download_file).and_return("Already saved quote line")
      dispatcher.dispatch(update(document: doc))
      expect(client).to have_received(:send_message).with(hash_including(text: a_string_including("No new quotes")))
    end

    it "rejects a non-txt document" do
      dispatcher.dispatch(update(document: doc(file_name: "photo.pdf", mime_type: "application/pdf")))
      expect(client).to have_received(:send_message).with(hash_including(text: a_string_including("only import plain .txt")))
    end

    it "accepts a text/plain file even without a .txt name" do
      allow(client).to receive(:download_file).and_return("A good quote line here")
      dispatcher.dispatch(update(document: doc(file_name: "quotes", mime_type: "text/plain")))
      expect(user.quotes.count).to eq(1)
    end

    it "rejects a file over the byte cap without downloading it" do
      allow(client).to receive(:download_file)
      dispatcher.dispatch(update(document: doc(file_size: QuoteImporter::MAX_BYTES + 1)))
      expect(client).not_to have_received(:download_file)
      expect(client).to have_received(:send_message).with(hash_including(text: a_string_including("too large")))
    end

    it "tells the user when the file can't be read" do
      allow(client).to receive(:download_file).and_return(nil)
      dispatcher.dispatch(update(document: doc))
      expect(client).to have_received(:send_message).with(hash_including(text: a_string_including("couldn't read")))
    end

    it "surfaces a friendly message if the download raises" do
      allow(client).to receive(:download_file).and_raise(TelegramClient::Error, "boom")
      expect { dispatcher.dispatch(update(document: doc)) }.not_to raise_error
      expect(client).to have_received(:send_message).with(hash_including(text: a_string_including("couldn't read")))
    end
  end

  describe "leaving the import state" do
    it "drops awaiting_import_file when the user sends text instead of a file" do
      user.update!(state: "awaiting_import_file")
      dispatcher.dispatch(update(text: "A quote I typed instead of uploading"))
      expect(user.reload.state).to be_nil
      # And it is treated as a normal capture, not swallowed.
      expect(client).to have_received(:send_message).with(hash_including(text: a_string_including("Add this as a quote")))
    end
  end
end
