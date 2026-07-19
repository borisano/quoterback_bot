# Scoped aggregate stats for one user's collection (plan §9.6). All queries are
# scoped through the user association, so there is no cross-user access.
class UserStatsQuery
  Stats = Struct.new(
    :total_quotes, :distinct_authors, :favourites, :with_images,
    :current_streak, :quotes_delivered, :top_tags,
    keyword_init: true
  )

  def self.call(user)
    new(user).call
  end

  def initialize(user)
    @user = user
  end

  def call
    Stats.new(
      total_quotes: @user.quotes.count,
      distinct_authors: @user.quotes.where.not(author: [ nil, "" ]).distinct.count(:author),
      favourites: @user.quotes.favourited.count,
      with_images: @user.quotes.where.not(photo_file_id: [ nil, "" ]).count,
      current_streak: @user.streak_count.to_i,
      quotes_delivered: @user.quote_deliveries.count,
      top_tags: top_tags
    )
  end

  private

  # Up to three most-used tags as [name, count] pairs.
  def top_tags
    @user.tags
         .left_joins(:taggings)
         .group("tags.id")
         .order(Arel.sql("COUNT(taggings.id) DESC"))
         .order("tags.name")
         .limit(3)
         .pluck("tags.name", Arel.sql("COUNT(taggings.id)"))
  end
end
