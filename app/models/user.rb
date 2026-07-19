class User < ApplicationRecord
  has_many :quotes, dependent: :destroy
  has_many :tags, dependent: :destroy
  has_many :delivery_schedules, dependent: :destroy
  has_many :quote_deliveries, dependent: :destroy

  STATES = %w[
    new
    awaiting_timezone
    awaiting_schedule_time
    awaiting_quote_text
    awaiting_quote_text_for_photo
    awaiting_image_for_quote
    awaiting_import_file
    awaiting_tag_name
    ready
  ].freeze

  validates :telegram_chat_id, presence: true, uniqueness: true
  validates :active, inclusion: { in: [ true, false ] }
  validates :timezone,
            inclusion: { in: ActiveSupport::TimeZone.all.map(&:tzinfo).map(&:name).uniq },
            allow_nil: true
  validates :state, inclusion: { in: STATES }, allow_nil: true

  scope :active, -> { where(active: true) }

  def self.find_or_create_from_update!(update)
    user = find_or_initialize_by(telegram_chat_id: update.chat_id)
    user.first_name = update.first_name if update.first_name.present?
    user.telegram_language_code = update.language_code if update.language_code.present?
    user.last_interaction_at = Time.current
    user.save!
    user
  rescue ActiveRecord::RecordNotUnique
    retry
  end

  def configured?
    timezone.present?
  end

  def awaiting_state?
    state.present?
  end

  # Free-tier quote-count cap (plan §9.7 — stub, no payments yet). Enforced at the
  # QuoteCreator choke point so every capture path is covered. Schedules and images
  # are deliberately NOT gated.
  FREE_QUOTE_LIMIT = 20

  # Stub until payment integration lands: nobody is premium yet.
  def premium?
    false
  end
end
