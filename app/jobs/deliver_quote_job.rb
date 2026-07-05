class DeliverQuoteJob < ApplicationJob
  queue_as :default

  def perform(schedule_id, date_str)
    # Implementation in phase 3, step 2
  end
end
