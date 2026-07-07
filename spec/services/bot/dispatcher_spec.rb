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

    context "when a handler raises (C7 — error policy)" do
      before { allow(User).to receive(:find_or_create_from_update!).and_raise(StandardError, "boom") }

      it "does not propagate the error" do
        expect { dispatcher.dispatch(parsed_update(text: "/quote")) }.not_to raise_error
      end

      it "reports the exception to Rollbar" do
        allow(Rollbar).to receive(:error)
        dispatcher.dispatch(parsed_update(text: "/quote"))
        expect(Rollbar).to have_received(:error)
      end

      it "clears the callback spinner when the failing update was a callback" do
        dispatcher.dispatch(parsed_update(callback_data: "q:rand:0", callback_query_id: "cqX"))
        expect(client).to have_received(:answer_callback_query).with(
          hash_including(callback_query_id: "cqX")
        )
      end

      it "does not try to answer a callback for a plain text update" do
        dispatcher.dispatch(parsed_update(text: "/quote"))
        expect(client).not_to have_received(:answer_callback_query)
      end

      it "still swallows a failure inside the rescue's callback answer" do
        allow(client).to receive(:answer_callback_query).and_raise(StandardError, "client down")
        expect {
          dispatcher.dispatch(parsed_update(callback_data: "q:rand:0", callback_query_id: "cqX"))
        }.not_to raise_error
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

    context "with /command@BotName form (M1)" do
      it "treats /quote@Bot as /quote" do
        dispatcher.dispatch(parsed_update(text: "/quote@QuoterBackBot"))
        expect(client).to have_received(:send_message).with(
          hash_including(text: a_string_including("no quotes"))
        )
      end

      it "does not fall through to confirm-on-text" do
        dispatcher.dispatch(parsed_update(text: "/help@QuoterBackBot"))
        expect(client).not_to have_received(:send_message).with(
          hash_including(text: a_string_including("Add this as a quote"))
        )
        expect(client).to have_received(:send_message).with(
          hash_including(text: a_string_including("QuoterBack Help"))
        )
      end

      it "passes the argument through for /command@Bot arg" do
        expect {
          dispatcher.dispatch(parsed_update(text: "/add@QuoterBackBot A perfectly valid quote here."))
        }.to change { user.quotes.count }.by(1)
      end

      it "honors /cancel@Bot as a state escape" do
        user.update!(state: "awaiting_quote_text")
        dispatcher.dispatch(parsed_update(text: "/cancel@QuoterBackBot"))
        expect(user.reload.state).to be_nil
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

    context "with /add command and invalid content (C3 — no silent dead-end)" do
      it "does not create a quote for too-short text" do
        expect {
          dispatcher.dispatch(parsed_update(text: "/add hi"))
        }.not_to change { user.quotes.count }
      end

      it "replies with a human validation message" do
        dispatcher.dispatch(parsed_update(text: "/add hi"))
        expect(client).to have_received(:send_message).with(
          hash_including(chat_id: 111, text: a_string_including("3"))
        )
      end

      it "does not create a quote for too-long text" do
        expect {
          dispatcher.dispatch(parsed_update(text: "/add #{'x' * 1001}"))
        }.not_to change { user.quotes.count }
      end
    end

    context "when user is in awaiting_quote_text state" do
      before { user.update!(state: "awaiting_quote_text") }

      it "creates a quote from the text" do
        expect {
          dispatcher.dispatch(parsed_update(text: "To be or not to be."))
        }.to change { user.quotes.count }.by(1)
      end

      context "with invalid content (C3 — must not wedge the state machine)" do
        it "does not create a quote" do
          expect {
            dispatcher.dispatch(parsed_update(text: "hi"))
          }.not_to change { user.quotes.count }
        end

        it "keeps the user in awaiting_quote_text so they can retry" do
          dispatcher.dispatch(parsed_update(text: "hi"))
          expect(user.reload.state).to eq("awaiting_quote_text")
        end

        it "replies with a human validation message" do
          dispatcher.dispatch(parsed_update(text: "hi"))
          expect(client).to have_received(:send_message).with(
            hash_including(text: a_string_including("3"))
          )
        end

        it "does NOT fall through to confirm-on-text" do
          dispatcher.dispatch(parsed_update(text: "hi"))
          expect(client).not_to have_received(:send_message).with(
            hash_including(text: a_string_including("Add this as a quote"))
          )
        end
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

      context "keyboard row width (C1 — Telegram caps inline rows at 8 buttons)" do
        def captured_keyboard
          captured = nil
          allow(client).to receive(:send_message) { |args| captured = args }
          dispatcher.dispatch(parsed_update(text: "/list"))
          captured.dig(:reply_markup, :inline_keyboard)
        end

        it "keeps every row at or under 8 buttons with a full page of 10 quotes" do
          create_list(:quote, 10, user: user)
          captured_keyboard.each do |row|
            expect(row.size).to be <= 8
          end
        end

        it "splits the 10 number buttons across multiple rows" do
          create_list(:quote, 10, user: user)
          number_rows = captured_keyboard.select do |row|
            row.all? { |btn| btn[:callback_data].to_s.start_with?("q:show:") }
          end
          expect(number_rows.size).to be >= 2
          expect(number_rows.sum(&:size)).to eq(10)
        end

        it "still exposes every quote as a numbered button" do
          create_list(:quote, 10, user: user)
          show_ids = captured_keyboard.flatten.filter_map do |btn|
            btn[:callback_data][/\Aq:show:(\d+)\z/, 1]&.to_i
          end
          expect(show_ids.size).to eq(10)
        end

        it "keeps rows small on a partial page too (7 quotes)" do
          create_list(:quote, 7, user: user)
          captured_keyboard.each do |row|
            expect(row.size).to be <= 8
          end
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

      context "qc:yes:<token> with invalid cached content (C3)" do
        let(:token) { "toolongtoken" }

        before do
          Rails.cache.write(
            "pending_quote:#{token}",
            { from_id: 111, chat_id: 111, text: "x" * 1001 },
            expires_in: 10.minutes
          )
        end

        it "does not create a quote" do
          expect {
            dispatcher.dispatch(parsed_update(callback_data: "qc:yes:#{token}", callback_query_id: "cqbad"))
          }.not_to change { user.quotes.count }
        end

        it "does not raise" do
          expect {
            dispatcher.dispatch(parsed_update(callback_data: "qc:yes:#{token}", callback_query_id: "cqbad"))
          }.not_to raise_error
        end

        it "tells the user with a human message" do
          dispatcher.dispatch(parsed_update(callback_data: "qc:yes:#{token}", callback_query_id: "cqbad"))
          expect(client).to have_received(:send_message).with(
            hash_including(text: a_string_including("1000"))
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

  # ── C2: plain-text copy (no literal Markdown asterisks) ─────────────────────

  context "plain-text bot copy (C2 — no parse_mode, so no literal '*')" do
    def all_sent_texts
      sent = []
      allow(client).to receive(:send_message) { |args| sent << args[:text] }
      allow(client).to receive(:edit_message_text) { |args| sent << args[:text] }
      sent
    end

    it "/start greeting contains no asterisks" do
      texts = all_sent_texts
      dispatcher.dispatch(parsed_update(text: "/start"))
      expect(texts.join).not_to include("*")
    end

    it "/settings panel contains no asterisks" do
      texts = all_sent_texts
      dispatcher.dispatch(parsed_update(text: "/settings"))
      expect(texts.join).not_to include("*")
    end

    it "/help contains no asterisks" do
      texts = all_sent_texts
      dispatcher.dispatch(parsed_update(text: "/help"))
      expect(texts.join).not_to include("*")
    end

    it "/timezones contains no asterisks" do
      texts = all_sent_texts
      dispatcher.dispatch(parsed_update(text: "/timezones"))
      expect(texts.join).not_to include("*")
    end

    it "/list header contains no asterisks" do
      create_list(:quote, 3, user: user)
      texts = all_sent_texts
      dispatcher.dispatch(parsed_update(text: "/list"))
      expect(texts.join).not_to include("*")
    end

    it "timezone confirmation contains no asterisks (first-time onboarding)" do
      user.update!(timezone: nil)
      texts = all_sent_texts
      dispatcher.dispatch(parsed_update(text: "/settimezone London"))
      expect(texts.join).not_to include("*")
    end

    it "timezone confirmation contains no asterisks (update)" do
      user.update!(timezone: "America/New_York")
      texts = all_sent_texts
      dispatcher.dispatch(parsed_update(text: "/settimezone London"))
      expect(texts.join).not_to include("*")
    end

    it "schedule confirmation contains no asterisks" do
      user.update!(timezone: "Europe/London")
      allow(QuoteScheduler).to receive(:schedule_for)
      texts = all_sent_texts
      dispatcher.dispatch(parsed_update(text: "/schedule 09:00"))
      expect(texts.join).not_to include("*")
    end

    it "tag confirmation contains no asterisks" do
      quote = create(:quote, user: user)
      user.update!(state: "awaiting_tag_name")
      Rails.cache.write("pending_tag_quote:#{user.telegram_chat_id}", quote.id, expires_in: 10.minutes)
      texts = all_sent_texts
      dispatcher.dispatch(parsed_update(text: "stoic"))
      expect(texts.join).not_to include("*")
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

      it "sends the error message BEFORE the picker (M3 — correct order)" do
        sent = []
        allow(client).to receive(:send_message) { |args| sent << args[:text] }
        dispatcher.dispatch(parsed_update(text: "/settimezone notazone"))
        error_idx  = sent.index { |t| t.include?("Couldn't recognize") }
        picker_idx = sent.index { |t| t.include?("Choose your timezone") }
        expect(error_idx).not_to be_nil
        expect(picker_idx).not_to be_nil
        expect(error_idx).to be < picker_idx
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

  context "with q:rand:<schedule_id> callback (C5 — scoped 'Another')" do
    let!(:tag) { create(:tag, user: user, name: "stoic") }
    let!(:in_scope) { create(:quote, user: user, content: "Amor fati — love your fate.") }
    let!(:out_scope) { create(:quote, user: user, content: "Totally unrelated content here.") }
    let!(:schedule) { create(:delivery_schedule, user: user, tag: tag, hour: 9, minute: 0) }
    before { in_scope.taggings.create!(tag: tag) }

    it "returns a quote from the schedule's tag scope only" do
      dispatcher.dispatch(parsed_update(callback_data: "q:rand:#{schedule.id}", callback_query_id: "cr1"))
      expect(client).to have_received(:edit_message_text).with(
        hash_including(text: a_string_including("Amor fati"))
      )
    end

    it "falls back to the whole collection for q:rand:0" do
      out_scope.update!(content: "Only quote left standing.")
      in_scope.destroy
      dispatcher.dispatch(parsed_update(callback_data: "q:rand:0", callback_query_id: "cr2"))
      expect(client).to have_received(:edit_message_text).with(
        hash_including(text: a_string_including("Only quote left standing."))
      )
    end

    it "ignores another user's schedule id and uses the whole collection" do
      other = create(:user)
      other_sched = create(:delivery_schedule, user: other, hour: 8, minute: 0)
      expect {
        dispatcher.dispatch(parsed_update(callback_data: "q:rand:#{other_sched.id}", callback_query_id: "cr3"))
      }.not_to raise_error
      expect(client).to have_received(:edit_message_text)
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

    context "with a name longer than 30 chars (C3 — must not wedge the state machine)" do
      it "does not create a tag" do
        expect {
          dispatcher.dispatch(parsed_update(text: "a" * 31))
        }.not_to change { user.tags.count }
      end

      it "keeps the user in awaiting_tag_name to retry" do
        dispatcher.dispatch(parsed_update(text: "a" * 31))
        expect(user.reload.state).to eq("awaiting_tag_name")
      end

      it "replies with a clear message" do
        dispatcher.dispatch(parsed_update(text: "a" * 31))
        expect(client).to have_received(:send_message).with(
          hash_including(text: a_string_including("30"))
        )
      end
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
