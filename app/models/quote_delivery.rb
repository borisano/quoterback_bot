class QuoteDelivery < ApplicationRecord
  belongs_to :user
  belongs_to :quote, optional: true
  belongs_to :delivery_schedule, optional: true

  validates :local_date, presence: true
  validates :delivered_at, presence: true
  validates :context, inclusion: { in: %w[scheduled on_demand] }
end
