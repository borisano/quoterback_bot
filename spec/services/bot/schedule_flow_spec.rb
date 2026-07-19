require "rails_helper"

# Covers the button-first /schedule builder and the /schedules manager (G1,
# plan §9.3). The dispatcher is exercised end-to-end with a doubled client.
RSpec.describe Bot::Dispatcher, "schedule builder + manager (G1)" do
  let(:client) { double("TelegramClient") } # rubocop:disable RSpec/VerifiedDoubles
  let(:user) { create(:user, telegram_chat_id: 111, timezone: "Europe/London") }
  let(:dispatcher) { described_class.new(client: client) }

  before do
    allow(User).to receive(:find_or_create_from_update!).and_return(user)
    allow(client).to receive(:send_message)
    allow(client).to receive(:edit_message_text)
    allow(client).to receive(:answer_callback_query)
    allow(QuoteScheduler).to receive(:schedule_for)
    allow(QuoteScheduler).to receive(:cancel_pending_for)
    Rails.cache.clear
  end

  def update(text: nil, callback_data: nil, callback_query_id: nil, chat_id: 111, from_id: 111, message_id: 42)
    Bot::UpdateParser::ParsedUpdate.new(
      chat_id: chat_id, from_id: from_id, first_name: "Tester", language_code: "en",
      text: text, callback_data: callback_data, callback_query_id: callback_query_id, message_id: message_id
    )
  end

  # ── Builder ────────────────────────────────────────────────────────────────

  describe "the /schedule builder" do
    it "requires a timezone before anything else" do
      user.update!(timezone: nil)
      dispatcher.dispatch(update(text: "/schedule"))
      expect(client).to have_received(:send_message).with(hash_including(text: a_string_including("timezone")))
    end

    it "opens the scope chooser with an Any option and one button per tag" do
      create(:tag, user: user, name: "stoic")
      dispatcher.dispatch(update(text: "/schedule"))
      expect(client).to have_received(:send_message) do |args|
        expect(args[:text]).to include("which quotes")
        cbs = args[:reply_markup][:inline_keyboard].flatten.map { |b| b[:callback_data] }
        expect(cbs).to include("sched:tag:any")
        expect(cbs).to include(a_string_matching(/\Asched:tag:\d+\z/))
      end
    end

    it "walks tag → hour → minute → confirm → create for a tag-scoped schedule" do
      tag = create(:tag, user: user, name: "stoic")

      dispatcher.dispatch(update(text: "/schedule"))
      dispatcher.dispatch(update(callback_data: "sched:tag:#{tag.id}", callback_query_id: "c1"))
      dispatcher.dispatch(update(callback_data: "sched:h:9", callback_query_id: "c2"))
      dispatcher.dispatch(update(callback_data: "sched:m:30", callback_query_id: "c3"))

      # Confirm card shows the assembled choice
      expect(client).to have_received(:edit_message_text).with(
        hash_including(text: a_string_including("09:30"))
      )

      expect {
        dispatcher.dispatch(update(callback_data: "sched:create", callback_query_id: "c4"))
      }.to change { user.delivery_schedules.count }.by(1)

      schedule = user.delivery_schedules.last
      expect(schedule).to have_attributes(hour: 9, minute: 30, tag_id: tag.id, enabled: true)
      expect(QuoteScheduler).to have_received(:schedule_for).with(schedule)
    end

    it "creates a whole-collection schedule when Any is chosen" do
      dispatcher.dispatch(update(text: "/schedule"))
      dispatcher.dispatch(update(callback_data: "sched:tag:any", callback_query_id: "c1"))
      dispatcher.dispatch(update(callback_data: "sched:h:7", callback_query_id: "c2"))
      dispatcher.dispatch(update(callback_data: "sched:m:0", callback_query_id: "c3"))
      dispatcher.dispatch(update(callback_data: "sched:create", callback_query_id: "c4"))

      schedule = user.delivery_schedules.last
      expect(schedule.tag_id).to be_nil
      expect(schedule.hour).to eq(7)
    end

    it "renders a full 24-hour grid after a scope is picked" do
      dispatcher.dispatch(update(text: "/schedule"))
      dispatcher.dispatch(update(callback_data: "sched:tag:any", callback_query_id: "c1"))

      keyboard = nil
      expect(client).to have_received(:edit_message_text) do |args|
        keyboard = args[:reply_markup][:inline_keyboard] if args[:text].to_s.include?("hour")
      end
      hour_buttons = keyboard.flatten.select { |b| b[:callback_data].to_s.start_with?("sched:h:") }
      expect(hour_buttons.size).to eq(24)
      expect(keyboard.flatten).to all(satisfy { |b| b[:callback_data].to_s.length <= 64 })
    end

    it "ignores a tag id that is not the user's" do
      other_tag = create(:tag, user: create(:user, telegram_chat_id: 222), name: "theirs")
      dispatcher.dispatch(update(text: "/schedule"))
      dispatcher.dispatch(update(callback_data: "sched:tag:#{other_tag.id}", callback_query_id: "c1"))
      expect(client).to have_received(:answer_callback_query).with(
        hash_including(callback_query_id: "c1", text: a_string_including("gone"))
      )
    end

    it "reports an expired setup if the builder cache is gone" do
      # Jump straight to a step with no builder entry in cache.
      dispatcher.dispatch(update(callback_data: "sched:h:9", callback_query_id: "c1"))
      expect(client).to have_received(:send_message).with(hash_including(text: a_string_including("expired")))
    end

    it "keeps the builder alive on a crafted out-of-range hour (sched:h:24)" do
      dispatcher.dispatch(update(text: "/schedule"))
      dispatcher.dispatch(update(callback_data: "sched:tag:any", callback_query_id: "c1"))
      dispatcher.dispatch(update(callback_data: "sched:h:24", callback_query_id: "c2"))
      expect(client).to have_received(:answer_callback_query).with(hash_including(text: a_string_including("0–23")))
      # The builder survives, so a valid hour then continues normally.
      dispatcher.dispatch(update(callback_data: "sched:h:9", callback_query_id: "c3"))
      dispatcher.dispatch(update(callback_data: "sched:m:0", callback_query_id: "c4"))
      expect {
        dispatcher.dispatch(update(callback_data: "sched:create", callback_query_id: "c5"))
      }.to change { user.delivery_schedules.count }.by(1)
    end

    it "re-opens the scope chooser if the chosen tag was deleted before Create" do
      tag = create(:tag, user: user, name: "stoic")
      dispatcher.dispatch(update(text: "/schedule"))
      dispatcher.dispatch(update(callback_data: "sched:tag:#{tag.id}", callback_query_id: "c1"))
      dispatcher.dispatch(update(callback_data: "sched:h:9", callback_query_id: "c2"))
      dispatcher.dispatch(update(callback_data: "sched:m:0", callback_query_id: "c3"))
      tag.destroy
      expect {
        dispatcher.dispatch(update(callback_data: "sched:create", callback_query_id: "c4"))
      }.not_to change { user.delivery_schedules.count }
      expect(client).to have_received(:answer_callback_query).with(hash_including(text: a_string_including("removed")))
    end

    it "does not stack an identical whole-collection schedule" do
      create(:delivery_schedule, user: user, hour: 9, minute: 0, tag: nil)
      dispatcher.dispatch(update(text: "/schedule"))
      dispatcher.dispatch(update(callback_data: "sched:tag:any", callback_query_id: "c1"))
      dispatcher.dispatch(update(callback_data: "sched:h:9", callback_query_id: "c2"))
      dispatcher.dispatch(update(callback_data: "sched:m:0", callback_query_id: "c3"))
      expect {
        dispatcher.dispatch(update(callback_data: "sched:create", callback_query_id: "c4"))
      }.not_to change { user.delivery_schedules.count }
      expect(client).to have_received(:answer_callback_query).with(hash_including(text: a_string_including("already")))
    end

    it "cancels cleanly and clears state" do
      dispatcher.dispatch(update(text: "/schedule"))
      dispatcher.dispatch(update(callback_data: "sched:cancel", callback_query_id: "c1"))
      expect(client).to have_received(:edit_message_text).with(hash_including(text: a_string_including("cancelled")))
      # A follow-up step now finds nothing and reports expiry rather than acting.
      dispatcher.dispatch(update(callback_data: "sched:h:9", callback_query_id: "c2"))
      expect(client).to have_received(:send_message).with(hash_including(text: a_string_including("expired")))
    end
  end

  # ── Typed fallback ───────────────────────────────────────────────────────────

  describe "the /schedule HH:MM typed fallback" do
    it "creates a whole-collection schedule directly" do
      expect {
        dispatcher.dispatch(update(text: "/schedule 14:30"))
      }.to change { user.delivery_schedules.count }.by(1)
      s = user.delivery_schedules.last
      expect(s).to have_attributes(hour: 14, minute: 30, tag_id: nil, enabled: true)
    end

    it "rejects a malformed time" do
      dispatcher.dispatch(update(text: "/schedule 9pm"))
      expect(client).to have_received(:send_message).with(hash_including(text: a_string_including("HH:MM")))
    end

    it "rejects an out-of-range time" do
      dispatcher.dispatch(update(text: "/schedule 25:00"))
      expect(client).to have_received(:send_message).with(hash_including(text: a_string_including("Invalid")))
    end

    it "does not create a duplicate when the same time is typed twice" do
      dispatcher.dispatch(update(text: "/schedule 09:00"))
      expect {
        dispatcher.dispatch(update(text: "/schedule 09:00"))
      }.not_to change { user.delivery_schedules.count }
      expect(client).to have_received(:send_message).with(hash_including(text: a_string_including("already have")))
    end
  end

  # ── Manager ──────────────────────────────────────────────────────────────────

  describe "the /schedules manager" do
    it "shows an empty state with a New schedule button when there are none" do
      dispatcher.dispatch(update(text: "/schedules"))
      expect(client).to have_received(:send_message).with(
        hash_including(
          text: a_string_including("no delivery schedules"),
          reply_markup: hash_including(inline_keyboard: [ [ hash_including(callback_data: "sched:new") ] ])
        )
      )
    end

    it "lists each schedule with edit / pause / delete controls" do
      tag = create(:tag, user: user, name: "stoic")
      create(:delivery_schedule, user: user, hour: 9, minute: 0, tag: tag)
      create(:delivery_schedule, user: user, hour: 21, minute: 0)

      dispatcher.dispatch(update(text: "/schedules"))

      expect(client).to have_received(:send_message) do |args|
        expect(args[:text]).to include("09:00").and include("#stoic").and include("21:00")
        cbs = args[:reply_markup][:inline_keyboard].flatten.map { |b| b[:callback_data] }
        expect(cbs).to include(a_string_matching(/\Asched:edit:\d+\z/))
        expect(cbs).to include(a_string_matching(/\Asched:toggle:\d+\z/))
        expect(cbs).to include(a_string_matching(/\Asched:del:\d+\z/))
      end
    end

    it "is reachable from the settings Schedules button (set:sched)" do
      create(:delivery_schedule, user: user, hour: 9, minute: 0)
      dispatcher.dispatch(update(callback_data: "set:sched", callback_query_id: "c1"))
      expect(client).to have_received(:send_message).with(hash_including(text: a_string_including("delivery schedules")))
    end

    describe "pause / resume toggle" do
      let!(:schedule) { create(:delivery_schedule, user: user, hour: 9, minute: 0, enabled: true) }

      it "pauses an enabled schedule and cancels its pending job" do
        dispatcher.dispatch(update(callback_data: "sched:toggle:#{schedule.id}", callback_query_id: "c1"))
        expect(schedule.reload.enabled).to be false
        expect(QuoteScheduler).to have_received(:cancel_pending_for).with(schedule)
        expect(client).to have_received(:answer_callback_query).with(hash_including(text: a_string_including("Paused")))
      end

      it "resumes a paused schedule and reschedules it" do
        schedule.update!(enabled: false)
        dispatcher.dispatch(update(callback_data: "sched:toggle:#{schedule.id}", callback_query_id: "c1"))
        expect(schedule.reload.enabled).to be true
        expect(QuoteScheduler).to have_received(:schedule_for).with(schedule)
        expect(client).to have_received(:answer_callback_query).with(hash_including(text: a_string_including("Resumed")))
      end
    end

    describe "delete flow" do
      let!(:schedule) { create(:delivery_schedule, user: user, hour: 9, minute: 0) }

      it "asks for confirmation on sched:del" do
        dispatcher.dispatch(update(callback_data: "sched:del:#{schedule.id}", callback_query_id: "c1"))
        expect(client).to have_received(:edit_message_text).with(
          hash_including(
            text: a_string_including("Delete this schedule"),
            reply_markup: hash_including(inline_keyboard: [ array_including(
              hash_including(callback_data: "sched:dely:#{schedule.id}"),
              hash_including(callback_data: "sched:deln:#{schedule.id}")
            ) ])
          )
        )
      end

      it "destroys the schedule on confirm" do
        expect {
          dispatcher.dispatch(update(callback_data: "sched:dely:#{schedule.id}", callback_query_id: "c1"))
        }.to change { user.delivery_schedules.count }.by(-1)
      end

      it "keeps the schedule on cancel" do
        expect {
          dispatcher.dispatch(update(callback_data: "sched:deln:#{schedule.id}", callback_query_id: "c1"))
        }.not_to change { user.delivery_schedules.count }
      end
    end

    describe "editing an existing schedule" do
      let!(:schedule) { create(:delivery_schedule, user: user, hour: 9, minute: 0) }

      it "re-runs the builder and updates the same row instead of creating a new one" do
        dispatcher.dispatch(update(callback_data: "sched:edit:#{schedule.id}", callback_query_id: "c1"))
        dispatcher.dispatch(update(callback_data: "sched:tag:any", callback_query_id: "c2"))
        dispatcher.dispatch(update(callback_data: "sched:h:20", callback_query_id: "c3"))
        dispatcher.dispatch(update(callback_data: "sched:m:15", callback_query_id: "c4"))

        expect {
          dispatcher.dispatch(update(callback_data: "sched:create", callback_query_id: "c5"))
        }.not_to change { user.delivery_schedules.count }

        expect(schedule.reload).to have_attributes(hour: 20, minute: 15)
      end

      it "reports the row is gone if the edited schedule was deleted before Create" do
        dispatcher.dispatch(update(callback_data: "sched:edit:#{schedule.id}", callback_query_id: "c1"))
        dispatcher.dispatch(update(callback_data: "sched:tag:any", callback_query_id: "c2"))
        dispatcher.dispatch(update(callback_data: "sched:h:20", callback_query_id: "c3"))
        dispatcher.dispatch(update(callback_data: "sched:m:15", callback_query_id: "c4"))
        schedule.destroy
        expect {
          dispatcher.dispatch(update(callback_data: "sched:create", callback_query_id: "c5"))
        }.not_to change { user.delivery_schedules.count }
        expect(client).to have_received(:answer_callback_query).with(hash_including(text: a_string_including("gone")))
      end
    end

    describe "ownership" do
      it "ignores toggle for another user's schedule id" do
        other = create(:user, telegram_chat_id: 222, timezone: "Europe/London")
        other_sched = create(:delivery_schedule, user: other, hour: 8, minute: 0, enabled: true)
        dispatcher.dispatch(update(callback_data: "sched:toggle:#{other_sched.id}", callback_query_id: "c1"))
        expect(other_sched.reload.enabled).to be true
        expect(client).to have_received(:answer_callback_query).with(hash_including(text: a_string_including("gone")))
      end
    end
  end
end
