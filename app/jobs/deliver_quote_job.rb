class DeliverQuoteJob < ApplicationJob
  queue_as :default

  # retry_on runs first. When all attempts are exhausted the block fires to
  # reschedule — this REPLACES the separate discard_on (which preempts retry_on
  # when declared for the same class, defeating retries entirely).
  retry_on TelegramClient::Error, wait: 30.seconds, attempts: 3 do |job, error|
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

    # Stale-job guard: bail if this is a duplicate or stale job
    return if job_id != schedule.pending_job_id

    quote = Quote.random_for(user, tag: schedule.tag)

    # The Telegram send is intentionally OUTSIDE any rescue so TelegramClient::Error
    # propagates up to retry_on, and TelegramClient::Forbidden is caught below.
    if quote
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

      # Post-send bookkeeping — wrapped so errors here never prevent reschedule
      record_delivery(quote, schedule, user)
    end

    # Always reschedule, even with no quote (keeps empty-scope schedules ticking)
    reschedule(schedule)
  rescue TelegramClient::Forbidden => e
    Rails.logger.warn("[DeliverQuoteJob] bot blocked by user #{user&.telegram_chat_id}: #{e.message}")
    user&.update!(active: false)
    # Do NOT reschedule on 403
  end

  private

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
  rescue => e
    Rails.logger.error("[DeliverQuoteJob] post-send bookkeeping error: #{e.class} — #{e.message}")
  end

  def update_streak(user, local_date)
    user.with_lock do
      if user.streak_last_date == local_date
        # Already counted today — no change
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
