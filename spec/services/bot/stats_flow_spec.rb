require "rails_helper"

# Covers /stats (G9) and the free-tier quote limit surfacing (G8) in the dispatcher.
RSpec.describe Bot::Dispatcher, "stats + free-tier limit (G9/G8)" do
  let(:client) { double("TelegramClient") } # rubocop:disable RSpec/VerifiedDoubles
  let(:user) { create(:user, telegram_chat_id: 111, timezone: "Europe/London") }
  let(:dispatcher) { described_class.new(client: client) }

  before do
    allow(User).to receive(:find_or_create_from_update!).and_return(user)
    allow(client).to receive(:send_message)
    allow(client).to receive(:edit_message_text)
    allow(client).to receive(:answer_callback_query)
    Rails.cache.clear
  end

  def update(text: nil, callback_data: nil, callback_query_id: nil, chat_id: 111, from_id: 111, message_id: 42)
    Bot::UpdateParser::ParsedUpdate.new(
      chat_id: chat_id, from_id: from_id, first_name: "Tester", language_code: "en",
      text: text, callback_data: callback_data, callback_query_id: callback_query_id, message_id: message_id
    )
  end

  describe "/stats" do
    it "shows an encouraging empty state with no quotes" do
      dispatcher.dispatch(update(text: "/stats"))
      expect(client).to have_received(:send_message).with(hash_including(text: a_string_including("No stats yet")))
    end

    it "reports totals, quota, streak and top tags" do
      user.update!(streak_count: 3)
      3.times { create(:quote, user: user, author: "Seneca") }
      tag = create(:tag, user: user, name: "stoic")
      user.quotes.first.taggings.create!(tag: tag)

      dispatcher.dispatch(update(text: "/stats"))
      expect(client).to have_received(:send_message) do |args|
        expect(args[:text]).to include("Quotes: 3 / #{User::FREE_QUOTE_LIMIT}")
        expect(args[:text]).to include("Current streak: 3 days")
        expect(args[:text]).to include("#stoic (1)")
      end
    end

    it "is reachable from the settings Stats button (set:stats)" do
      create(:quote, user: user)
      dispatcher.dispatch(update(callback_data: "set:stats", callback_query_id: "c1"))
      expect(client).to have_received(:send_message).with(hash_including(text: a_string_including("Your stats")))
    end
  end

  describe "the free-tier limit surfaced through the dispatcher" do
    before { create_list(:quote, User::FREE_QUOTE_LIMIT, user: user) }

    it "blocks /add and offers the manage-quotes remedy" do
      expect {
        dispatcher.dispatch(update(text: "/add One more valid quote please"))
      }.not_to change { user.quotes.count }
      expect(client).to have_received(:send_message).with(
        hash_including(
          text: a_string_including("free limit"),
          reply_markup: hash_including(inline_keyboard: [ [ hash_including(callback_data: "list:pg:1") ] ])
        )
      )
    end

    it "blocks a plain-text capture confirmation and clears no state" do
      dispatcher.dispatch(update(text: "A plain message that would be a quote"))
      # confirm-on-text still offered; the limit bites on the yes-tap.
      cb = nil
      expect(client).to have_received(:send_message) do |args|
        kb = args.dig(:reply_markup, :inline_keyboard)
        cb ||= kb&.flatten&.map { |b| b[:callback_data] }&.find { |d| d.to_s.start_with?("qc:yes:") }
      end
      expect {
        dispatcher.dispatch(update(callback_data: cb, callback_query_id: "c1"))
      }.not_to change { user.quotes.count }
    end

    it "ends the awaiting_quote_text flow instead of looping on the limit" do
      dispatcher.dispatch(update(text: "/add"))          # enters awaiting_quote_text
      expect(user.reload.state).to eq("awaiting_quote_text")
      dispatcher.dispatch(update(text: "Trying to add past the limit"))
      expect(user.reload.state).to be_nil                # terminal, not a retry loop
      expect(client).to have_received(:send_message).with(hash_including(text: a_string_including("free limit")))
    end
  end

  describe "import respects the free-tier limit" do
    before { create_list(:quote, User::FREE_QUOTE_LIMIT - 2, user: user) }

    it "imports only up to the cap and skips the rest" do
      allow(client).to receive(:download_file).and_return("New quote one here\nNew quote two here\nNew quote three here")
      doc = { file_id: "FID", file_name: "q.txt", file_size: 80, mime_type: "text/plain" }
      dispatcher.dispatch(
        Bot::UpdateParser::ParsedUpdate.new(
          chat_id: 111, from_id: 111, first_name: "T", language_code: "en",
          text: nil, callback_data: nil, callback_query_id: nil, message_id: 1, document: doc
        )
      )
      expect(user.quotes.count).to eq(User::FREE_QUOTE_LIMIT) # 18 + 2 imported, 3rd skipped
      expect(client).to have_received(:send_message).with(hash_including(text: a_string_including("skipped 1")))
    end
  end
end
