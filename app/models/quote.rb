class Quote < ApplicationRecord
  belongs_to :user
  has_many :taggings, dependent: :destroy
  has_many :tags, through: :taggings

  has_one_attached :image

  validates :content, presence: true, length: { minimum: 3, maximum: 1000 }
  validates :author, length: { maximum: 100 }, allow_blank: true
  validates :source, length: { maximum: 200 }, allow_blank: true

  scope :favourited, -> { where(favourited: true) }
  scope :by_tag, ->(tag) { joins(:taggings).where(taggings: { tag_id: tag.id }) }
  scope :for_user, ->(user) { where(user_id: user.id) }

  def self.random_for(user)
    user.quotes.order(Arel.sql("last_delivered_at ASC NULLS FIRST")).first(20).sample
  end
end
