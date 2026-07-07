class Tag < ApplicationRecord
  belongs_to :user
  has_many :taggings, dependent: :destroy
  has_many :quotes, through: :taggings
  has_many :delivery_schedules, dependent: :destroy

  validates :name, presence: true, length: { maximum: 30 }
  validates :name, uniqueness: { scope: :user_id }
  validates :name, format: { with: /\A[a-z0-9_]+\z/ }, allow_blank: true

  before_validation :normalize_name

  # Single source of truth for tag name normalization (M8): strip leading #,
  # downcase, trim, and collapse internal whitespace to underscores. The
  # dispatcher calls this for lookups so stored names and queries always agree.
  def self.normalize(raw)
    raw.to_s.sub(/\A#+/, "").strip.downcase.gsub(/\s+/, "_")
  end

  private

  def normalize_name
    self.name = self.class.normalize(name) if name.present?
  end
end
