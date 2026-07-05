require "rails_helper"

RSpec.describe ScheduleQuotesJob, type: :job do
  describe "#perform" do
    let!(:active_user) { create(:user, :with_timezone) }
    let!(:schedule) { create(:delivery_schedule, user: active_user, enabled: true) }

    before do
      allow(QuoteScheduler).to receive(:schedule_for)
      allow(QuoteScheduler).to receive(:pending_job_exists_for?).and_return(false)
    end

    it "schedules jobs for enabled schedules with no pending job" do
      described_class.perform_now
      expect(QuoteScheduler).to have_received(:schedule_for).with(schedule)
    end

    it "skips schedules that already have a pending job" do
      allow(QuoteScheduler).to receive(:pending_job_exists_for?).and_return(true)
      described_class.perform_now
      expect(QuoteScheduler).not_to have_received(:schedule_for)
    end

    it "skips disabled schedules" do
      schedule.update!(enabled: false)
      described_class.perform_now
      expect(QuoteScheduler).not_to have_received(:schedule_for)
    end

    it "skips inactive users" do
      active_user.update!(active: false)
      described_class.perform_now
      expect(QuoteScheduler).not_to have_received(:schedule_for)
    end

    it "skips users without a timezone" do
      active_user.update!(timezone: nil)
      described_class.perform_now
      expect(QuoteScheduler).not_to have_received(:schedule_for)
    end
  end
end
