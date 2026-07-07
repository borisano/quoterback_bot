require "rails_helper"

RSpec.describe QuoteScheduler do
  let(:user) { create(:user, :with_timezone, timezone: "Europe/London") }
  let(:schedule) { create(:delivery_schedule, user: user, hour: 9, minute: 0) }

  describe ".next_run_time" do
    it "returns today's run time if it's still in the future" do
      travel_to Time.zone.parse("2024-06-15 08:00:00 UTC") do
        run_at = described_class.next_run_time(schedule)
        expect(run_at.hour).to eq(9)
        expect(run_at.min).to eq(0)
        expect(run_at.to_date).to eq(Date.parse("2024-06-15"))
      end
    end

    it "returns tomorrow's run time if today's has passed" do
      travel_to Time.zone.parse("2024-06-15 10:00:00 UTC") do
        run_at = described_class.next_run_time(schedule)
        expect(run_at.to_date).to eq(Date.parse("2024-06-16"))
      end
    end

    it "uses the user's timezone, not UTC" do
      user.update!(timezone: "America/New_York")
      # 08:00 UTC = 04:00 ET → still future for 09:00 ET today
      travel_to Time.zone.parse("2024-06-15 08:00:00 UTC") do
        run_at = described_class.next_run_time(schedule)
        expect(run_at.to_date).to eq(Date.parse("2024-06-15"))
      end
    end

    it "accepts a DST-gap time without special handling (Rails resolves it)" do
      user.update!(timezone: "America/New_York")
      schedule.update!(hour: 2, minute: 30)
      # Spring forward: 2024-03-10 02:30 ET does not exist — Rails resolves to 03:30
      travel_to Time.zone.parse("2024-03-10 00:00:00 UTC") do
        expect { described_class.next_run_time(schedule) }.not_to raise_error
      end
    end
  end

  describe ".schedule_for" do
    it "enqueues a DeliverQuoteJob" do
      expect { described_class.schedule_for(schedule) }
        .to have_enqueued_job(DeliverQuoteJob)
    end

    it "writes pending_job_id to the schedule" do
      described_class.schedule_for(schedule)
      expect(schedule.reload.pending_job_id).not_to be_nil
    end

    it "persists pending_job_id BEFORE the job is enqueued (C4 — closes the cross-DB race)" do
      persisted_at_enqueue = :not_called
      allow_any_instance_of(DeliverQuoteJob).to receive(:enqueue) do |job, *_|
        persisted_at_enqueue = schedule.reload.pending_job_id
        job
      end

      described_class.schedule_for(schedule)

      expect(persisted_at_enqueue).to be_present
      expect(persisted_at_enqueue).to eq(schedule.reload.pending_job_id)
    end

    it "clears pending_job_id if the enqueue raises" do
      allow_any_instance_of(DeliverQuoteJob).to receive(:enqueue).and_raise(RuntimeError, "queue down")
      expect { described_class.schedule_for(schedule) }.to raise_error(RuntimeError)
      expect(schedule.reload.pending_job_id).to be_nil
    end

    it "does nothing when schedule is disabled" do
      schedule.update!(enabled: false)
      expect { described_class.schedule_for(schedule) }
        .not_to have_enqueued_job(DeliverQuoteJob)
    end

    it "does nothing when user is inactive" do
      user.update!(active: false)
      expect { described_class.schedule_for(schedule) }
        .not_to have_enqueued_job(DeliverQuoteJob)
    end

    it "does nothing when user has no timezone" do
      user.update!(timezone: nil)
      expect { described_class.schedule_for(schedule) }
        .not_to have_enqueued_job(DeliverQuoteJob)
    end

    it "cancels any existing pending job before scheduling a new one" do
      # First schedule
      described_class.schedule_for(schedule)
      old_job_id = schedule.reload.pending_job_id

      # Second schedule should replace it
      described_class.schedule_for(schedule.reload)
      new_job_id = schedule.reload.pending_job_id

      expect(new_job_id).not_to eq(old_job_id)
    end
  end

  describe ".cancel_pending_for" do
    it "clears pending_job_id" do
      schedule.update!(pending_job_id: "some-job-id")
      described_class.cancel_pending_for(schedule)
      expect(schedule.reload.pending_job_id).to be_nil
    end

    it "does not raise when pending_job_id is nil" do
      expect { described_class.cancel_pending_for(schedule) }.not_to raise_error
    end
  end

  describe ".pending_job_exists_for?" do
    it "returns false when pending_job_id is nil" do
      expect(described_class.pending_job_exists_for?(schedule)).to be false
    end

    it "returns false when no live SolidQueue job matches" do
      schedule.update!(pending_job_id: "nonexistent-id")
      expect(described_class.pending_job_exists_for?(schedule)).to be false
    end
  end
end
