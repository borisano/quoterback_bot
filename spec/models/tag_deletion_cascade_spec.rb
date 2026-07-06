require "rails_helper"

RSpec.describe "Tag deletion cascade", type: :model do
  it "cancels pending jobs on tag-scoped schedules when the tag is destroyed" do
    user = create(:user, :with_timezone)
    tag = create(:tag, user: user)
    schedule = create(:delivery_schedule, user: user, tag: tag, pending_job_id: "job-123")

    allow(QuoteScheduler).to receive(:cancel_pending_for)
    tag.destroy
    expect(QuoteScheduler).to have_received(:cancel_pending_for).with(schedule)
  end
end
