class DeliverQuoteJob < ApplicationJob
  queue_as :default

  retry_on TelegramClient::Error, wait: 30.seconds, attempts: 3

  discard_on TelegramClient::Error do |job, error|
    Rails.logger.error("[DeliverQuoteJob] exhausted retries for schedule #{job.arguments.first}: #{error.message}")
    schedule = DeliverySchedule.find_by(id: job.arguments.first)
    QuoteScheduler.schedule_for(schedule) if schedule
  end

  def perform(schedule_id, date_str)
    schedule = DeliverySchedule.find_by(id: schedule_id)
    return unless schedule
    return unless schedule.enabled?

    user = schedule.user
    return unless user.active?

    return if job_id != schedule.pending_job_id

    quote = select_quote(schedule, user)

    send_quote(quote, schedule, user) if quote
    reschedule(schedule)
  rescue TelegramClient::Forbidden => e
    Rails.logger.warn("[DeliverQuoteJob] bot blocked by user #{user&.telegram_chat_id}: #{e.message}")
    user&.update!(active: false)
  rescue StandardError => e
    Rails.logger.error("[DeliverQuoteJob] unexpected error: #{e.class} — #{e.message}")
    reschedule(schedule) rescue nil
  end

  private

  def select_quote(schedule, user)
    scope = if schedule.tag_id.present?
      user.quotes.joins(:taggings).where(taggings: { tag_id: schedule.tag_id })
    else
      user.quotes
    end
    scope.order(Arel.sql("last_delivered_at ASC NULLS FIRST")).first(20).sample
  end

  def send_quote(quote, schedule, user)
    presenter = Bot::QuotePresenter.new(quote)
    TelegramClient.from_env.send_message(
      chat_id: user.telegram_chat_id,
      text: presenter.message_text,
      reply_markup: {
        inline_keyboard: [[
          { text: "🗑 Delete", callback_data: "q:del:#{quote.id}" },
          { text: "🎲 Another", callback_data: "q:rand:#{schedule.id}" }
        ]]
      }
    )

    record_delivery(quote, schedule, user)
  rescue TelegramClient::Forbidden
    raise
  rescue => e
    Rails.logger.error("[DeliverQuoteJob] post-send error: #{e.class} — #{e.message}")
  end

  def record_delivery(quote, schedule, user)
    local_date = Time.current.in_time_zone(user.timezone).to_date

    user.quote_deliveries.create!(
      quote: quote,
      delivery_schedule: schedule,
      local_date: local_date,
      context: "scheduled",
      delivered_at: Time.current
    )

    quote.update!(
      times_delivered: quote.times_delivered + 1,
      last_delivered_at: Time.current
    )

    update_streak(user, local_date)
  rescue ActiveRecord::RecordNotUnique
    Rails.logger.info("[DeliverQuoteJob] delivery already logged for schedule #{schedule.id} on #{local_date}")
  end

  def update_streak(user, local_date)
    user.with_lock do
      if user.streak_last_date == local_date
        # Already counted today
      elsif user.streak_last_date == local_date - 1
        user.update!(streak_count: user.streak_count + 1, streak_last_date: local_date)
      else
        user.update!(streak_count: 1, streak_last_date: local_date)
      end
    end
  end

  def reschedule(schedule)
    schedule.reload
    QuoteScheduler.schedule_for(schedule)
  rescue => e
    Rails.logger.error("[DeliverQuoteJob] reschedule failed: #{e.class} — #{e.message}")
  end
end
