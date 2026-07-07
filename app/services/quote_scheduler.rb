module QuoteScheduler
  module_function

  def schedule_for(schedule)
    return unless schedule.enabled?
    return unless schedule.user.active?
    return unless schedule.user.timezone.present?

    cancel_pending_for(schedule)

    run_at = next_run_time(schedule)

    # Persist the id BEFORE enqueuing so the stale-job guard in DeliverQuoteJob
    # can never see a mismatch for a job that starts before the write commits.
    # A transaction cannot cover this: in production Solid Queue lives in a
    # separate database, so the job INSERT is not part of the primary-DB
    # transaction (C4). Ordering is the real fix; the guard is the backstop.
    job = DeliverQuoteJob.new(schedule.id, run_at.to_date.iso8601)
    schedule.update!(pending_job_id: job.job_id)

    begin
      job.enqueue(wait_until: run_at)
    rescue StandardError
      schedule.update!(pending_job_id: nil)
      raise
    end
  end

  def next_run_time(schedule)
    user = schedule.user
    tz = ActiveSupport::TimeZone[user.timezone]
    now_in_tz = Time.current.in_time_zone(tz)

    candidate = tz.local(
      now_in_tz.year,
      now_in_tz.month,
      now_in_tz.day,
      schedule.hour,
      schedule.minute,
      0
    )

    candidate >= Time.current ? candidate : candidate + 1.day
  end

  def cancel_pending_for(schedule)
    return unless schedule.pending_job_id.present?

    begin
      SolidQueue::Job
        .where(active_job_id: schedule.pending_job_id, finished_at: nil)
        .each { |job| job.discard rescue nil }
    rescue ActiveRecord::StatementInvalid, ActiveRecord::NoDatabaseError
      # SolidQueue tables not available (e.g., test environment)
    end

    schedule.update!(pending_job_id: nil)
  end

  def pending_job_exists_for?(schedule)
    return false unless schedule.pending_job_id.present?

    SolidQueue::Job
      .where(active_job_id: schedule.pending_job_id, finished_at: nil)
      .exists?
  rescue ActiveRecord::StatementInvalid, ActiveRecord::NoDatabaseError
    false
  end
end
