class ScheduleQuotesJob < ApplicationJob
  queue_as :default

  def perform
    Rails.logger.info("[ScheduleQuotesJob] running safety net")

    DeliverySchedule
      .where(enabled: true)
      .joins(:user)
      .merge(User.active)
      .where.not(users: { timezone: nil })
      .find_each do |schedule|
        next if QuoteScheduler.pending_job_exists_for?(schedule)

        QuoteScheduler.schedule_for(schedule)
      rescue => e
        Rails.logger.error("[ScheduleQuotesJob] error scheduling #{schedule.id}: #{e.message}")
      end
  end
end
