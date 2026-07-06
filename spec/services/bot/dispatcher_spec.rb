require "rails_helper"

RSpec.describe Bot::Dispatcher do
  let(:client) { double("TelegramClient") }  # rubocop:disable RSpec/VerifiedDoubles
  let(:user) { create(:user, telegram_chat_id: 111) }
  let(:dispatcher) { described_class.new(client: client) }

  before do
    allow(User).to receive(:find_or_create_from_update!).and_return(user)
    allow(client).to receive(:send_message)
    allow(client).to receive(:edit_message_text)
    allow(client).to receive(:answer_callback_query)
  end

  def parsed_update(text: nil, chat_id: 111, callback_data: nil, callback_query_id: nil, from_id: 111, message_id: 42)
    Bot::UpdateParser::ParsedUpdate.new(
      chat_id: chat_id,
      from_id: from_id,
      first_name: "Tester",
      language_code: "en",
      text: text,
      callback_data: callback_data,
      callback_query_id: callback_query_id,
      message_id: message_id
    )
  end

  describe "#dispatch" do
    context "with nil update" do
      it "does nothing and does not raise" do
        expect { dispatcher.dispatch(nil) }.not_to raise_error
      end
    end

    context "with /ping command" do
      it "sends 'Pong!' back to the user" do
        dispatcher.dispatch(parsed_update(text: "/ping"))
        expect(client).to have_received(:send_message).with(
          chat_id: 111,
          text: "🏓 Pong!"
        )
      end
    end

    context "with /start command" do
      it "sends a welcome message with inline keyboard" do
        dispatcher.dispatch(parsed_update(text: "/start"))
        expect(client).to have_received(:send_message).with(
          hash_including(chat_id: 111, text: a_string_including("Welcome"))
        )
      end
    end

    context "with 'ping me in N minutes' text" do
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

      it "does NOT also trigger confirm-on-text" do
        dispatcher.dispatch(parsed_update(text: "ping me in 1 minute"))
        expect(client).not_to have_received(:send_message).with(
          hash_including(text: a_string_including("Add this as a quote"))
        )
      end
    end

    context "with /add command" do
      context "with quote text inline" do
        it "creates a quote and confirms" do
          expect {
            dispatcher.dispatch(parsed_update(text: "/add The unexamined life is not worth living."))
          }.to change { user.quotes.count }.by(1)
        end

        it "sends a success message" do
          dispatcher.dispatch(parsed_update(text: "/add Be the change you wish to see."))
          expect(client).to have_received(:send_message).with(
            hash_including(chat_id: 111, text: a_string_including("✅"))
          )
        end
      end

      context "without text" do
        it "sets user state to awaiting_quote_text" do
          dispatcher.dispatch(parsed_update(text: "/add"))
          expect(user.reload.state).to eq("awaiting_quote_text")
        end

        it "prompts for quote text" do
          dispatcher.dispatch(parsed_update(text: "/add"))
          expect(client).to have_received(:send_message).with(
            hash_including(chat_id: 111, text: a_string_including("send"))
          )
        end
      end
    end

    context "when user is in awaiting_quote_text state" do
      before { user.update!(state: "awaiting_quote_text") }

      it "creates a quote from the text" do
        expect {
          dispatcher.dispatch(parsed_update(text: "To be or not to be."))
        }.to change { user.quotes.count }.by(1)
      end

      it "clears the user state" do
        dispatcher.dispatch(parsed_update(text: "Knowledge is power."))
        expect(user.reload.state).to be_nil
      end

      it "sends a success message" do
        dispatcher.dispatch(parsed_update(text: "Live and let live."))
        expect(client).to have_received(:send_message).with(
          hash_including(chat_id: 111, text: a_string_including("✅"))
        )
      end

      it "does NOT trigger confirm-on-text" do
        dispatcher.dispatch(parsed_update(text: "Some plain text"))
        expect(client).not_to have_received(:send_message).with(
          hash_including(text: a_string_including("Add this as a quote"))
        )
      end
    end

    context "with plain text (not a command)" do
      it "asks the user to confirm adding it as a quote" do
        dispatcher.dispatch(parsed_update(text: "Life is beautiful"))
        expect(client).to have_received(:send_message).with(
          hash_including(
            chat_id: 111,
            text: a_string_including("Add this as a quote")
          )
        )
      end
    end

    context "with /quote command" do
      context "when user has no quotes" do
        it "tells user their collection is empty" do
          dispatcher.dispatch(parsed_update(text: "/quote"))
          expect(client).to have_received(:send_message).with(
            hash_including(chat_id: 111, text: a_string_including("no quotes"))
          )
        end
      end

      context "when user has quotes" do
        before { create(:quote, user: user) }

        it "sends a quote message" do
          dispatcher.dispatch(parsed_update(text: "/quote"))
          expect(client).to have_received(:send_message).with(
            hash_including(chat_id: 111)
          )
        end

        it "logs a quote_delivery" do
          expect {
            dispatcher.dispatch(parsed_update(text: "/quote"))
          }.to change { user.quote_deliveries.count }.by(1)
        end
      end
    end

    context "with /list command" do
      context "when user has no quotes" do
        it "tells user their collection is empty" do
          dispatcher.dispatch(parsed_update(text: "/list"))
          expect(client).to have_received(:send_message).with(
            hash_including(chat_id: 111, text: a_string_including("no quotes"))
          )
        end
      end

      context "when user has quotes" do
        before { create_list(:quote, 3, user: user) }

        it "sends a list message" do
          dispatcher.dispatch(parsed_update(text: "/list"))
          expect(client).to have_received(:send_message).with(
            hash_including(chat_id: 111, text: a_string_including("Your Quotes"))
          )
        end
      end

      context "with a #tag filter" do
        let!(:tag) { create(:tag, user: user, name: "stoic") }
        let!(:tagged) { create(:quote, user: user) }
        let!(:untagged) { create(:quote, user: user) }
        before { tagged.taggings.create!(tag: tag) }

        it "lists only quotes with that tag" do
          dispatcher.dispatch(parsed_update(text: "/list #stoic"))
          expect(client).to have_received(:send_message).with(
            hash_including(text: a_string_including("tagged #stoic"))
          )
        end

        it "carries the tag filter into pagination callbacks" do
          create_list(:quote, 12, user: user).each { |q| q.taggings.create!(tag: tag) }
          dispatcher.dispatch(parsed_update(text: "/list #stoic"))
          expect(client).to have_received(:send_message).with(
            hash_including(reply_markup: hash_including(:inline_keyboard))
          )
        end

        it "reports empty for a #tag with no quotes" do
          tagged.taggings.destroy_all
          dispatcher.dispatch(parsed_update(text: "/list #stoic"))
          expect(client).to have_received(:send_message).with(
            hash_including(text: a_string_including("no quotes tagged"))
          )
        end
      end
    end

    context "with /delete command" do
      let!(:quote) { create(:quote, user: user) }

      context "with valid quote id" do
        it "sends a delete confirmation" do
          dispatcher.dispatch(parsed_update(text: "/delete #{quote.id}"))
          expect(client).to have_received(:send_message).with(
            hash_including(chat_id: 111, text: a_string_including("Delete this quote"))
          )
        end
      end

      context "with invalid quote id" do
        it "tells user the quote is not found" do
          dispatcher.dispatch(parsed_update(text: "/delete 999999"))
          expect(client).to have_received(:send_message).with(
            hash_including(chat_id: 111, text: a_string_including("no longer here"))
          )
        end
      end

      context "with another user's quote id" do
        let(:other_user) { create(:user) }
        let!(:other_quote) { create(:quote, user: other_user) }

        it "treats it as not found (scoped to current user)" do
          dispatcher.dispatch(parsed_update(text: "/delete #{other_quote.id}"))
          expect(client).to have_received(:send_message).with(
            hash_including(chat_id: 111, text: a_string_including("no longer here"))
          )
        end
      end
    end

    context "with /settings command" do
      it "sends the settings panel" do
        dispatcher.dispatch(parsed_update(text: "/settings"))
        expect(client).to have_received(:send_message).with(
          hash_including(chat_id: 111, text: a_string_including("Settings"))
        )
      end
    end

    context "with /help command" do
      it "sends the help message" do
        dispatcher.dispatch(parsed_update(text: "/help"))
        expect(client).to have_received(:send_message).with(
          hash_including(chat_id: 111, text: a_string_including("QuoterBack Help"))
        )
      end
    end

    context "with callback data" do
      context "qc:yes:<token>" do
        let(:token) { "abc123token" }

        before do
          Rails.cache.write(
            "pending_quote:#{token}",
            { from_id: 111, chat_id: 111, text: "This is a great quote." },
            expires_in: 10.minutes
          )
        end

        it "creates a quote from the cached entry" do
          expect {
            dispatcher.dispatch(parsed_update(callback_data: "qc:yes:#{token}", callback_query_id: "cq1"))
          }.to change { user.quotes.count }.by(1)
        end

        it "answers the callback query" do
          dispatcher.dispatch(parsed_update(callback_data: "qc:yes:#{token}", callback_query_id: "cq1"))
          expect(client).to have_received(:answer_callback_query).with(
            hash_including(callback_query_id: "cq1")
          )
        end
      end

      context "qc:yes:<token> with expired token" do
        it "tells user the quote expired" do
          dispatcher.dispatch(parsed_update(callback_data: "qc:yes:expiredtoken", callback_query_id: "cq2"))
          expect(client).to have_received(:send_message).with(
            hash_including(chat_id: 111, text: a_string_including("expired"))
          )
        end
      end

      context "qc:yes:<token> with wrong from_id" do
        let(:token) { "wronguser123" }

        before do
          Rails.cache.write(
            "pending_quote:#{token}",
            { from_id: 999, chat_id: 111, text: "Someone else's quote." },
            expires_in: 10.minutes
          )
        end

        it "rejects the action" do
          dispatcher.dispatch(parsed_update(callback_data: "qc:yes:#{token}", callback_query_id: "cq3", from_id: 111))
          expect(client).to have_received(:answer_callback_query).with(
            hash_including(callback_query_id: "cq3")
          )
          expect(user.quotes.count).to eq(0)
        end
      end

      context "qc:no:<token>" do
        let(:token) { "deltoken456" }

        before do
          Rails.cache.write("pending_quote:#{token}", { from_id: 111, chat_id: 111, text: "Nah." })
        end

        it "deletes the cache entry" do
          dispatcher.dispatch(parsed_update(callback_data: "qc:no:#{token}", callback_query_id: "cq4"))
          expect(Rails.cache.read("pending_quote:#{token}")).to be_nil
        end
      end

      context "q:dely:<id>" do
        let!(:quote) { create(:quote, user: user) }

        it "destroys the quote" do
          expect {
            dispatcher.dispatch(parsed_update(callback_data: "q:dely:#{quote.id}", callback_query_id: "cq5"))
          }.to change { user.quotes.count }.by(-1)
        end
      end

      context "q:deln:<id>" do
        let!(:quote) { create(:quote, user: user) }

        it "does not destroy the quote" do
          expect {
            dispatcher.dispatch(parsed_update(callback_data: "q:deln:#{quote.id}", callback_query_id: "cq6"))
          }.not_to change { user.quotes.count }
        end
      end
    end
  end

  # ── /settimezone ────────────────────────────────────────────────────────────

  context "with /settimezone command" do
    context "with a valid timezone" do
      before { user.update!(timezone: "America/New_York") }

      it "sets the user's timezone" do
        dispatcher.dispatch(parsed_update(text: "/settimezone London"))
        expect(user.reload.timezone).to eq("Europe/London")
      end

      it "sends a confirmation message" do
        dispatcher.dispatch(parsed_update(text: "/settimezone London"))
        expect(client).to have_received(:send_message).with(
          hash_including(chat_id: 111, text: a_string_including("Timezone updated"))
        )
      end
    end

    context "setting timezone for the first time (onboarding)" do
      before { user.update!(timezone: nil) }

      it "shows the onboarding completion message" do
        dispatcher.dispatch(parsed_update(text: "/settimezone London"))
        expect(client).to have_received(:send_message).with(
          hash_including(text: a_string_including("all set"))
        )
      end

      it "offers an add-first-quote button" do
        dispatcher.dispatch(parsed_update(text: "/settimezone London"))
        expect(client).to have_received(:send_message).with(
          hash_including(reply_markup: hash_including(:inline_keyboard))
        )
      end
    end

    context "with a UTC offset" do
      it "resolves to a named timezone" do
        dispatcher.dispatch(parsed_update(text: "/settimezone +9"))
        expect(user.reload.timezone).not_to be_nil
      end
    end

    context "with an invalid timezone" do
      it "does not set the timezone" do
        dispatcher.dispatch(parsed_update(text: "/settimezone notazone"))
        expect(user.reload.timezone).to be_nil
      end

      it "re-shows the timezone picker with an inline keyboard (not a bare text dead-end)" do
        dispatcher.dispatch(parsed_update(text: "/settimezone notazone"))
        expect(client).to have_received(:send_message).with(
          hash_including(reply_markup: hash_including(:inline_keyboard))
        )
      end
    end

    context "bare /settimezone" do
      it "shows the common-zone picker" do
        dispatcher.dispatch(parsed_update(text: "/settimezone"))
        expect(client).to have_received(:send_message).with(
          hash_including(text: a_string_including("timezone"))
        )
      end
    end
  end

  context "when user is in awaiting_timezone state" do
    before { user.update!(state: "awaiting_timezone") }

    it "accepts a typed timezone and sets it" do
      dispatcher.dispatch(parsed_update(text: "London"))
      expect(user.reload.timezone).to eq("Europe/London")
    end

    it "clears the state after setting timezone" do
      dispatcher.dispatch(parsed_update(text: "London"))
      expect(user.reload.state).to be_nil
    end

    it "does NOT trigger confirm-on-text" do
      dispatcher.dispatch(parsed_update(text: "London"))
      expect(client).not_to have_received(:send_message).with(
        hash_including(text: a_string_including("Add this as a quote"))
      )
    end

    it "honors a /command escape hatch" do
      dispatcher.dispatch(parsed_update(text: "/ping"))
      expect(client).to have_received(:send_message).with(
        hash_including(text: "🏓 Pong!")
      )
    end
  end

  context "with /cancel command (state clearing)" do
    before { user.update!(state: "awaiting_quote_text") }

    it "clears the user state" do
      dispatcher.dispatch(parsed_update(text: "/cancel"))
      expect(user.reload.state).to be_nil
    end

    it "sends a cancellation message" do
      dispatcher.dispatch(parsed_update(text: "/cancel"))
      expect(client).to have_received(:send_message).with(
        hash_including(text: a_string_including("Cancelled"))
      )
    end
  end

  # ── /schedule ───────────────────────────────────────────────────────────────

  context "with /schedule command" do
    before do
      user.update!(timezone: "Europe/London")
      allow(QuoteScheduler).to receive(:schedule_for)
    end

    context "with HH:MM argument" do
      it "creates a delivery schedule" do
        expect {
          dispatcher.dispatch(parsed_update(text: "/schedule 09:00"))
        }.to change { user.delivery_schedules.count }.by(1)
      end

      it "sets the correct hour and minute" do
        dispatcher.dispatch(parsed_update(text: "/schedule 14:30"))
        schedule = user.delivery_schedules.last
        expect(schedule.hour).to eq(14)
        expect(schedule.minute).to eq(30)
      end

      it "confirms the schedule" do
        dispatcher.dispatch(parsed_update(text: "/schedule 09:00"))
        expect(client).to have_received(:send_message).with(
          hash_including(text: a_string_including("09:00"))
        )
      end

      it "updates existing schedule instead of creating a second one (MVP: one per user)" do
        create(:delivery_schedule, user: user, hour: 8, minute: 0)
        expect {
          dispatcher.dispatch(parsed_update(text: "/schedule 09:00"))
        }.not_to change { user.delivery_schedules.count }
        expect(user.delivery_schedules.last.hour).to eq(9)
      end
    end

    context "without argument" do
      it "prompts for time" do
        dispatcher.dispatch(parsed_update(text: "/schedule"))
        expect(client).to have_received(:send_message).with(
          hash_including(text: a_string_including("time"))
        )
      end
    end

    context "when user has no timezone" do
      before { user.update!(timezone: nil) }

      it "asks user to set timezone first" do
        dispatcher.dispatch(parsed_update(text: "/schedule 09:00"))
        expect(client).to have_received(:send_message).with(
          hash_including(text: a_string_including("timezone"))
        )
      end
    end
  end

  context "with /cancel command when schedule exists" do
    let!(:schedule) { create(:delivery_schedule, user: user, enabled: true) }

    before { allow(QuoteScheduler).to receive(:cancel_pending_for) }

    it "disables the schedule" do
      dispatcher.dispatch(parsed_update(text: "/cancel"))
      expect(schedule.reload.enabled).to be false
    end

    it "calls QuoteScheduler.cancel_pending_for" do
      dispatcher.dispatch(parsed_update(text: "/cancel"))
      expect(QuoteScheduler).to have_received(:cancel_pending_for)
    end
  end

  context "with q:tag:<id> callback" do
    let!(:quote) { create(:quote, user: user) }

    it "sends the tag picker" do
      dispatcher.dispatch(parsed_update(callback_data: "q:tag:#{quote.id}", callback_query_id: "cq1"))
      expect(client).to have_received(:send_message).with(
        hash_including(text: a_string_including("Tag this quote"))
      )
    end
  end

  context "with tag:add:<quote_id>:<tag_id> callback" do
    let!(:quote) { create(:quote, user: user) }
    let!(:tag) { create(:tag, user: user, name: "stoic") }

    it "adds the tag to the quote" do
      expect {
        dispatcher.dispatch(parsed_update(callback_data: "tag:add:#{quote.id}:#{tag.id}", callback_query_id: "cq2"))
      }.to change { quote.taggings.count }.by(1)
    end

    it "answers with a toast confirming the tag" do
      dispatcher.dispatch(parsed_update(callback_data: "tag:add:#{quote.id}:#{tag.id}", callback_query_id: "cq2"))
      expect(client).to have_received(:answer_callback_query).with(
        hash_including(text: a_string_including("stoic"))
      )
    end

    it "is idempotent — adding the same tag twice does not duplicate" do
      dispatcher.dispatch(parsed_update(callback_data: "tag:add:#{quote.id}:#{tag.id}", callback_query_id: "cq2"))
      expect {
        dispatcher.dispatch(parsed_update(callback_data: "tag:add:#{quote.id}:#{tag.id}", callback_query_id: "cq2"))
      }.not_to change { quote.taggings.count }
    end

    it "rejects another user's tag_id (no cross-user tagging)" do
      other_user = create(:user)
      other_tag = create(:tag, user: other_user, name: "theirs")
      expect {
        dispatcher.dispatch(parsed_update(callback_data: "tag:add:#{quote.id}:#{other_tag.id}", callback_query_id: "cq2"))
      }.not_to change { quote.taggings.count }
    end

    it "rejects another user's quote_id (no cross-user tagging)" do
      other_user = create(:user)
      other_quote = create(:quote, user: other_user)
      dispatcher.dispatch(parsed_update(callback_data: "tag:add:#{other_quote.id}:#{tag.id}", callback_query_id: "cq2"))
      expect(other_quote.taggings.count).to eq(0)
    end
  end

  context "with tag:rm:<quote_id>:<tag_id> callback" do
    let!(:quote) { create(:quote, user: user) }
    let!(:tag) { create(:tag, user: user, name: "stoic") }
    before { quote.taggings.create!(tag: tag) }

    it "removes the tag from the quote" do
      expect {
        dispatcher.dispatch(parsed_update(callback_data: "tag:rm:#{quote.id}:#{tag.id}", callback_query_id: "cq3"))
      }.to change { quote.taggings.count }.by(-1)
    end
  end

  context "with fav:toggle:<id> callback" do
    let!(:quote) { create(:quote, user: user, favourited: false) }

    it "toggles favourited to true" do
      dispatcher.dispatch(parsed_update(callback_data: "fav:toggle:#{quote.id}", callback_query_id: "cq4"))
      expect(quote.reload.favourited).to be true
    end

    it "answers with a heart toast" do
      dispatcher.dispatch(parsed_update(callback_data: "fav:toggle:#{quote.id}", callback_query_id: "cq4"))
      expect(client).to have_received(:answer_callback_query).with(
        hash_including(text: a_string_including("❤️"))
      )
    end

    it "toggles back to false on second tap" do
      quote.update!(favourited: true)
      dispatcher.dispatch(parsed_update(callback_data: "fav:toggle:#{quote.id}", callback_query_id: "cq4"))
      expect(quote.reload.favourited).to be false
    end
  end

  context "when in awaiting_tag_name state" do
    let!(:quote) { create(:quote, user: user) }
    before do
      user.update!(state: "awaiting_tag_name")
      Rails.cache.write("pending_tag_quote:#{user.telegram_chat_id}", quote.id, expires_in: 10.minutes)
    end

    it "creates a tag with the normalized name and applies it" do
      dispatcher.dispatch(parsed_update(text: "#STOIC"))
      expect(quote.reload.tags.map(&:name)).to include("stoic")
    end

    it "clears state after tagging" do
      dispatcher.dispatch(parsed_update(text: "motivation"))
      expect(user.reload.state).to be_nil
    end

    it "echoes the normalized name back" do
      dispatcher.dispatch(parsed_update(text: "#STOIC"))
      expect(client).to have_received(:send_message).with(
        hash_including(text: a_string_including("#stoic"))
      )
    end

    it "does NOT trigger confirm-on-text" do
      dispatcher.dispatch(parsed_update(text: "motivation"))
      expect(client).not_to have_received(:send_message).with(
        hash_including(text: a_string_including("Add this as a quote"))
      )
    end

    it "rejects invalid tag names" do
      dispatcher.dispatch(parsed_update(text: "!!!"))
      expect(user.reload.state).to eq("awaiting_tag_name") # stays in state
    end
  end

  context "with /quote #tag argument" do
    let!(:tag) { create(:tag, user: user, name: "stoic") }
    let!(:tagged_quote) { create(:quote, user: user) }
    before { tagged_quote.taggings.create!(tag: tag) }

    it "returns a quote from that tag" do
      dispatcher.dispatch(parsed_update(text: "/quote #stoic"))
      expect(client).to have_received(:send_message).with(
        hash_including(chat_id: 111)
      )
    end

    it "reports no quotes when tag is empty" do
      tagged_quote.taggings.destroy_all
      dispatcher.dispatch(parsed_update(text: "/quote #stoic"))
      expect(client).to have_received(:send_message).with(
        hash_including(text: a_string_including("no quotes tagged"))
      )
    end
  end

  context "with /quote bare-word that is not an existing tag" do
    it "falls back to random quote, NOT 'empty tag' (issue N11)" do
      create(:quote, user: user)
      dispatcher.dispatch(parsed_update(text: "/quote love"))
      expect(client).to have_received(:send_message).with(
        hash_including(chat_id: 111)
      )
      expect(client).not_to have_received(:send_message).with(
        hash_including(text: a_string_including("no quotes tagged"))
      )
    end
  end

  context "with /timezones command" do
    it "sends a list of common timezones with current local times" do
      dispatcher.dispatch(parsed_update(text: "/timezones"))
      expect(client).to have_received(:send_message).with(
        hash_including(text: a_string_including("timezone"))
      )
    end
  end

  context "with /start payload" do
    it "does not crash with an unknown payload" do
      expect { dispatcher.dispatch(parsed_update(text: "/start q_sometoken")) }.not_to raise_error
    end

    it "sends welcome message even with payload" do
      dispatcher.dispatch(parsed_update(text: "/start q_sometoken"))
      expect(client).to have_received(:send_message).with(
        hash_including(text: a_string_including("Welcome"))
      )
    end
  end

  context "with ob:addfirst callback" do
    it "sets state to awaiting_quote_text" do
      dispatcher.dispatch(parsed_update(callback_data: "ob:addfirst", callback_query_id: "ob1"))
      expect(user.reload.state).to eq("awaiting_quote_text")
    end

    it "prompts the user to send a quote" do
      dispatcher.dispatch(parsed_update(callback_data: "ob:addfirst", callback_query_id: "ob1"))
      expect(client).to have_received(:send_message).with(
        hash_including(text: a_string_including("first quote"))
      )
    end
  end
end
