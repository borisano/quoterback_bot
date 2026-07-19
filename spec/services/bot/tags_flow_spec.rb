require "rails_helper"

# Covers the /tags manager and the tag-delete flow with blast-radius warning
# (G6, plan §9.1/§8.5.5).
RSpec.describe Bot::Dispatcher, "tags manager (G6)" do
  let(:client) { double("TelegramClient") } # rubocop:disable RSpec/VerifiedDoubles
  let(:user) { create(:user, telegram_chat_id: 111, timezone: "Europe/London") }
  let(:dispatcher) { described_class.new(client: client) }

  before do
    allow(User).to receive(:find_or_create_from_update!).and_return(user)
    allow(client).to receive(:send_message)
    allow(client).to receive(:edit_message_text)
    allow(client).to receive(:answer_callback_query)
    allow(QuoteScheduler).to receive(:cancel_pending_for)
    allow(QuoteScheduler).to receive(:schedule_for)
  end

  def update(text: nil, callback_data: nil, callback_query_id: nil, chat_id: 111, from_id: 111, message_id: 42)
    Bot::UpdateParser::ParsedUpdate.new(
      chat_id: chat_id, from_id: from_id, first_name: "Tester", language_code: "en",
      text: text, callback_data: callback_data, callback_query_id: callback_query_id, message_id: message_id
    )
  end

  describe "/tags" do
    it "shows an empty state when the user has no tags" do
      dispatcher.dispatch(update(text: "/tags"))
      expect(client).to have_received(:send_message).with(hash_including(text: a_string_including("haven't created any tags")))
    end

    it "lists each tag with its quote count and a delete button" do
      stoic = create(:tag, user: user, name: "stoic")
      funny = create(:tag, user: user, name: "funny")
      q = create(:quote, user: user)
      q.taggings.create!(tag: stoic)

      dispatcher.dispatch(update(text: "/tags"))

      expect(client).to have_received(:send_message) do |args|
        expect(args[:text]).to include("#stoic — 1 quote").and include("#funny — 0 quotes")
        cbs = args[:reply_markup][:inline_keyboard].flatten.map { |b| b[:callback_data] }
        expect(cbs).to include("tag:del:#{stoic.id}", "tag:del:#{funny.id}")
        expect(cbs).to include("list:pg:1:#{stoic.id}") # browse-this-tag shortcut
      end
    end

    it "is reachable from the settings Tags button (set:tags)" do
      create(:tag, user: user, name: "stoic")
      dispatcher.dispatch(update(callback_data: "set:tags", callback_query_id: "c1"))
      expect(client).to have_received(:send_message).with(hash_including(text: a_string_including("Your tags")))
    end
  end

  describe "deleting a tag" do
    let!(:tag) { create(:tag, user: user, name: "movie") }

    it "asks for confirmation" do
      dispatcher.dispatch(update(callback_data: "tag:del:#{tag.id}", callback_query_id: "c1"))
      expect(client).to have_received(:edit_message_text).with(
        hash_including(
          text: a_string_including("Delete #movie"),
          reply_markup: hash_including(inline_keyboard: [ array_including(
            hash_including(callback_data: "tag:dely:#{tag.id}"),
            hash_including(callback_data: "tag:deln:#{tag.id}")
          ) ])
        )
      )
    end

    it "names the blast radius of affected schedules (§8.5.5)" do
      create(:delivery_schedule, user: user, tag: tag, hour: 9, minute: 0)
      create(:delivery_schedule, user: user, tag: tag, hour: 21, minute: 0)
      dispatcher.dispatch(update(callback_data: "tag:del:#{tag.id}", callback_query_id: "c1"))
      expect(client).to have_received(:edit_message_text).with(
        hash_including(text: a_string_including("2 schedules").and(a_string_including("09:00")).and(a_string_including("21:00")))
      )
    end

    it "does not mention schedules when there are none" do
      dispatcher.dispatch(update(callback_data: "tag:del:#{tag.id}", callback_query_id: "c1"))
      expect(client).to have_received(:edit_message_text) do |args|
        expect(args[:text]).to include("Delete #movie")
        expect(args[:text]).not_to include("schedule")
      end
    end

    it "destroys the tag on confirm but keeps the quotes" do
      q = create(:quote, user: user)
      q.taggings.create!(tag: tag)
      expect {
        dispatcher.dispatch(update(callback_data: "tag:dely:#{tag.id}", callback_query_id: "c1"))
      }.to change { user.tags.count }.by(-1)
      expect(user.quotes.count).to eq(1)
    end

    it "cancels pending jobs on the tag's schedules when deleted" do
      schedule = create(:delivery_schedule, user: user, tag: tag, hour: 9, minute: 0, pending_job_id: "job-1")
      dispatcher.dispatch(update(callback_data: "tag:dely:#{tag.id}", callback_query_id: "c1"))
      expect(QuoteScheduler).to have_received(:cancel_pending_for).with(schedule)
    end

    it "keeps the tag on cancel" do
      expect {
        dispatcher.dispatch(update(callback_data: "tag:deln:#{tag.id}", callback_query_id: "c1"))
      }.not_to change { user.tags.count }
    end

    it "ignores another user's tag id" do
      other = create(:user, telegram_chat_id: 222)
      other_tag = create(:tag, user: other, name: "theirs")
      expect {
        dispatcher.dispatch(update(callback_data: "tag:dely:#{other_tag.id}", callback_query_id: "c1"))
      }.not_to change { Tag.count }
      expect(client).to have_received(:answer_callback_query).with(hash_including(callback_query_id: "c1"))
    end
  end
end
