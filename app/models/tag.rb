class Tag < ApplicationRecord
  belongs_to :user
  has_many :taggings, dependent: :destroy
  has_many :quotes, through: :taggings
  has_many :delivery_schedules, dependent: :destroy

  validates :name, presence: true, length: { maximum: 30 }
  validates :name, uniqueness: { scope: :user_id }

  before_validation :normalize_name

  private

  def normalize_name
    self.name = name.to_s.gsub(/\A#/, "").downcase.strip if name.present?
  end
end
