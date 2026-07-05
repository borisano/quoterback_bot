class ScheduleQuotesJob < ApplicationJob
  queue_as :default

  def perform
    Rails.logger.info("[ScheduleQuotesJob] safety net running")
  end
end
