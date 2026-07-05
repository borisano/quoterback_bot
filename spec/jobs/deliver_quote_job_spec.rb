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
  end
end
