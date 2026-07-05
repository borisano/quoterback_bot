class DeliverySchedule < ApplicationRecord
  belongs_to :user
  belongs_to :tag, optional: true

  validates :hour, presence: true, inclusion: { in: 0..23 }
  validates :minute, presence: true, inclusion: { in: 0..59 }
  validates :enabled, inclusion: { in: [true, false] }

  scope :enabled, -> { where(enabled: true) }
end
