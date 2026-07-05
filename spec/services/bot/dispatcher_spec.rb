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
end
