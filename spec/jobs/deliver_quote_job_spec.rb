require "rails_helper"

RSpec.describe DeliverQuoteJob, type: :job do
  let(:user) { create(:user, :with_timezone, timezone: "Europe/London") }
  let(:schedule) { create(:delivery_schedule, user: user, hour: 9, minute: 0) }
  let!(:quote) { create(:quote, user: user) }
  let(:client) { double("TelegramClient") }
  let(:date_str) { Date.current.iso8601 }

  before do
    allow(TelegramClient).to receive(:from_env).and_return(client)
    allow(client).to receive(:send_message)
    allow(QuoteScheduler).to receive(:schedule_for)
  end

  describe "#perform" do
    context "with a valid schedule and quotes" do
      before do
        schedule.update!(pending_job_id: "test-job-id")
      end

      it "sends a message to the user" do
        allow_any_instance_of(described_class).to receive(:job_id).and_return("test-job-id")
        described_class.perform_now(schedule.id, date_str)
        expect(client).to have_received(:send_message).with(
          hash_including(chat_id: user.telegram_chat_id)
        )
      end

      it "logs a quote_delivery" do
        allow_any_instance_of(described_class).to receive(:job_id).and_return("test-job-id")
        expect {
          described_class.perform_now(schedule.id, date_str)
        }.to change { QuoteDelivery.count }.by(1)
      end

      it "reschedules via QuoteScheduler" do
        allow_any_instance_of(described_class).to receive(:job_id).and_return("test-job-id")
        described_class.perform_now(schedule.id, date_str)
        expect(QuoteScheduler).to have_received(:schedule_for)
      end
    end

    describe "quote selection (unified via Quote.random_for)" do
      it "selects only from the schedule's tag scope (C5)" do
        tag = create(:tag, user: user, name: "stoic")
        in_scope = create(:quote, user: user, content: "In the tag scope.")
        create(:quote, user: user, content: "Out of the tag scope.")
        in_scope.taggings.create!(tag: tag)
        schedule.update!(tag: tag, pending_job_id: "test-job-id")

        allow_any_instance_of(described_class).to receive(:job_id).and_return("test-job-id")
        described_class.perform_now(schedule.id, date_str)

        expect(client).to have_received(:send_message).with(
          hash_including(text: a_string_including("In the tag scope."))
        )
      end
    end

    context "stale job guard" do
      it "does nothing when job_id does not match pending_job_id" do
        schedule.update!(pending_job_id: "different-id")
        allow_any_instance_of(described_class).to receive(:job_id).and_return("test-job-id")
        described_class.perform_now(schedule.id, date_str)
        expect(client).not_to have_received(:send_message)
      end
    end

    context "when schedule is gone" do
      it "returns without raising" do
        expect { described_class.perform_now(999_999, date_str) }.not_to raise_error
      end
    end

    context "when schedule is disabled" do
      before { schedule.update!(enabled: false, pending_job_id: "test-job-id") }

      it "does not send" do
        allow_any_instance_of(described_class).to receive(:job_id).and_return("test-job-id")
        described_class.perform_now(schedule.id, date_str)
        expect(client).not_to have_received(:send_message)
      end
    end

    context "when user is inactive" do
      before do
        user.update!(active: false)
        schedule.update!(pending_job_id: "test-job-id")
      end

      it "does not send" do
        allow_any_instance_of(described_class).to receive(:job_id).and_return("test-job-id")
        described_class.perform_now(schedule.id, date_str)
        expect(client).not_to have_received(:send_message)
      end
    end

    context "when user has no quotes" do
      before do
        user.quotes.destroy_all
        schedule.update!(pending_job_id: "test-job-id")
      end

      it "still reschedules (empty scope keeps ticking)" do
        allow_any_instance_of(described_class).to receive(:job_id).and_return("test-job-id")
        described_class.perform_now(schedule.id, date_str)
        expect(QuoteScheduler).to have_received(:schedule_for)
      end

      it "does not send" do
        allow_any_instance_of(described_class).to receive(:job_id).and_return("test-job-id")
        described_class.perform_now(schedule.id, date_str)
        expect(client).not_to have_received(:send_message)
      end
    end

    context "when Telegram returns Forbidden (bot blocked)" do
      before do
        schedule.update!(pending_job_id: "test-job-id")
        allow(client).to receive(:send_message).and_raise(TelegramClient::Forbidden, "blocked")
      end

      it "marks user as inactive" do
        allow_any_instance_of(described_class).to receive(:job_id).and_return("test-job-id")
        described_class.perform_now(schedule.id, date_str)
        expect(user.reload.active).to be false
      end

      it "does not reschedule" do
        allow_any_instance_of(described_class).to receive(:job_id).and_return("test-job-id")
        described_class.perform_now(schedule.id, date_str)
        expect(QuoteScheduler).not_to have_received(:schedule_for)
      end
    end

    context "when Telegram returns a transient Error (non-403)" do
      before do
        schedule.update!(pending_job_id: "test-job-id")
        allow(client).to receive(:send_message).and_raise(TelegramClient::Error, "timeout")
      end

      it "does NOT reschedule on first failure (retry_on intercepts for retry)" do
        allow_any_instance_of(described_class).to receive(:job_id).and_return("test-job-id")
        # retry_on catches TelegramClient::Error and re-enqueues — perform_now doesn't raise to caller
        described_class.perform_now(schedule.id, date_str)
        expect(QuoteScheduler).not_to have_received(:schedule_for)
      end

      it "does NOT mark user inactive (non-Forbidden errors are transient)" do
        allow_any_instance_of(described_class).to receive(:job_id).and_return("test-job-id")
        described_class.perform_now(schedule.id, date_str)
        expect(user.reload.active).to be true
      end
    end

    context "delivering a photo quote (G4)" do
      before do
        allow(client).to receive(:send_photo)
        quote.update!(photo_file_id: "FID")
        schedule.update!(pending_job_id: "test-job-id")
        allow_any_instance_of(described_class).to receive(:job_id).and_return("test-job-id")
      end

      it "sends the quote as a photo, not a text message" do
        described_class.perform_now(schedule.id, date_str)
        expect(client).to have_received(:send_photo).with(hash_including(chat_id: user.telegram_chat_id, photo: "FID"))
      end

      it "still deactivates a blocked user on Forbidden (not treated as a stale file_id)" do
        allow(client).to receive(:send_photo).and_raise(TelegramClient::Forbidden, "blocked")
        described_class.perform_now(schedule.id, date_str)
        expect(user.reload.active).to be false
        expect(QuoteScheduler).not_to have_received(:schedule_for)
      end
    end

    context "streak tracking" do
      before { schedule.update!(pending_job_id: "test-job-id") }

      it "sets streak to 1 on first delivery (no previous streak)" do
        allow_any_instance_of(described_class).to receive(:job_id).and_return("test-job-id")
        travel_to Time.zone.parse("2024-06-15 09:00:00 UTC") do
          described_class.perform_now(schedule.id, date_str)
        end
        expect(user.reload.streak_count).to eq(1)
      end

      it "increments streak when delivering on the next consecutive day" do
        user.update!(streak_count: 3, streak_last_date: Date.parse("2024-06-14"))
        allow_any_instance_of(described_class).to receive(:job_id).and_return("test-job-id")
        travel_to Time.zone.parse("2024-06-15 09:00:00 UTC") do
          described_class.perform_now(schedule.id, date_str)
        end
        expect(user.reload.streak_count).to eq(4)
      end

      it "does not change streak when delivering twice on the same day" do
        user.update!(streak_count: 3, streak_last_date: Date.parse("2024-06-15"))
        allow_any_instance_of(described_class).to receive(:job_id).and_return("test-job-id")
        travel_to Time.zone.parse("2024-06-15 09:00:00 UTC") do
          described_class.perform_now(schedule.id, date_str)
        end
        expect(user.reload.streak_count).to eq(3)
      end

      it "resets streak to 1 when a day is missed" do
        user.update!(streak_count: 5, streak_last_date: Date.parse("2024-06-10"))
        allow_any_instance_of(described_class).to receive(:job_id).and_return("test-job-id")
        travel_to Time.zone.parse("2024-06-15 09:00:00 UTC") do
          described_class.perform_now(schedule.id, date_str)
        end
        expect(user.reload.streak_count).to eq(1)
      end
    end
  end
end
