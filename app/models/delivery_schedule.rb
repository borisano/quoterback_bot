class DeliverySchedule < ApplicationRecord
  belongs_to :user
  belongs_to :tag, optional: true

  validates :hour, presence: true, inclusion: { in: 0..23 }
  validates :minute, presence: true, inclusion: { in: 0..59 }
  validates :enabled, inclusion: { in: [ true, false ] }

  scope :enabled, -> { where(enabled: true) }

  # Cancel any pending delivery job before the row is destroyed (e.g. when its
  # tag is deleted via dependent: :destroy) so no orphan job fires (§7.4).
  before_destroy :cancel_pending_job

  private

  def cancel_pending_job
    QuoteScheduler.cancel_pending_for(self)
  rescue StandardError => e
    Rails.logger.error("[DeliverySchedule] cancel_pending_job failed for #{id}: #{e.message}")
  end
end
