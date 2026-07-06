module Admin
  class StatsQuery
    def call
      {
        users_total:       User.count,
        users_active:      User.active.count,
        users_with_tz:     User.where.not(timezone: nil).count,
        users_scheduled:   DeliverySchedule.where(enabled: true).select(:user_id).distinct.count,
        quotes_total:      Quote.count,
        deliveries_today:  QuoteDelivery.where(delivered_at: Date.current.all_day).count,
        deliveries_all:    QuoteDelivery.count,
        top_authors:       Quote.where.not(author: [ nil, "" ]).group(:author).count.sort_by { |_, v| -v }.first(5).to_h,
        tags_total:        Tag.count
      }
    end
  end
end
