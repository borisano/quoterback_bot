class User < ApplicationRecord
  has_many :quotes, dependent: :destroy
  has_many :tags, dependent: :destroy
  has_many :delivery_schedules, dependent: :destroy
  has_many :quote_deliveries, dependent: :destroy

  validates :telegram_chat_id, presence: true, uniqueness: true
  validates :active, inclusion: { in: [ true, false ] }

  scope :active, -> { where(active: true) }

  def self.find_or_create_from_update!(update)
    user = find_or_initialize_by(telegram_chat_id: update.chat_id)
    user.first_name = update.first_name if update.first_name.present?
    user.telegram_language_code = update.language_code if update.language_code.present?
    user.last_interaction_at = Time.current
    user.save!
    user
  end

  def configured?
    timezone.present?
  end

  def awaiting_state?
    state.present?
  end
end
