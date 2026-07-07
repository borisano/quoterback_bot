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

  # Favourited quotes get FAVOURITE_WEIGHT entries in the sample pool vs 1 for
  # the rest, so they are ~3x more likely to be chosen while non-favourites
  # still appear. Shared by on-demand /quote and scheduled delivery (C5).
  FAVOURITE_WEIGHT = 3
  CANDIDATE_POOL_SIZE = 20

  # Picks a quote for the user, optionally scoped to a tag, from a
  # least-recently-delivered candidate pool with favourite weighting.
  def self.random_for(user, tag: nil)
    scope = tag ? user.quotes.joins(:taggings).where(taggings: { tag_id: tag.id }) : user.quotes
    candidates = scope.order(Arel.sql("last_delivered_at ASC NULLS FIRST")).first(CANDIDATE_POOL_SIZE)
    weighted_sample(candidates)
  end

  def self.weighted_sample(quotes)
    weighted_pool(quotes).sample
  end

  def self.weighted_pool(quotes)
    quotes.flat_map { |q| q.favourited? ? [ q ] * FAVOURITE_WEIGHT : [ q ] }
  end
end
