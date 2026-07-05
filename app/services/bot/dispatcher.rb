module Bot
  # Routes a normalized ParsedUpdate to the appropriate handler.
  # Keep this class thin — delegate heavy work to service objects and jobs.
  class Dispatcher
    PAGE_SIZE = 10

    def initialize(client: TelegramClient.from_env)
      @client = client
    end

    def dispatch(update)
      return if update.nil?

      user = User.find_or_create_from_update!(update)

      if update.callback_data
        handle_callback(update, user)
      elsif update.text.present?
        handle_text(update, user)
      end
    rescue StandardError => e
      Rails.logger.error("[Bot::Dispatcher] Error: #{e.class} — #{e.message}")
    end

    private

    attr_reader :client

    def handle_text(update, user)
      text = update.text.strip

      if user.state == "awaiting_quote_text"
        return handle_awaiting_quote_text(update, user, text)
      end

      command, rest = text.split(/\s+/, 2)

      case command.downcase
      when "/start"               then handle_start(update, user)
      when "/ping"                then handle_ping(update)
      when "/add"                 then handle_add(update, user, rest)
      when "/quote", "/random"    then handle_quote(update, user)
      when "/list", "/quotes"     then handle_list(update, user)
      when "/delete"              then handle_delete_command(update, user, rest)
      when "/settings"            then handle_settings(update, user)
      when "/help"                then handle_help(update, user)
      else
        handle_schedule_ping(update) if text.match?(/ping me in/i)
        handle_confirm_on_text(update, user, text) unless text.start_with?("/")
      end
    end

    def handle_callback(update, user)
      data = update.callback_data.to_s

      case data
      when /\Aob:tz\z/
        client.send_message(chat_id: update.chat_id, text: "🌍 Timezone setup coming soon! For now use /settimezone")
      when /\Aob:help\z/
        handle_help(update, user)
      when /\Aqc:yes:(.+)\z/
        handle_quote_confirm_yes(update, user, $1)
      when /\Aqc:no:(.+)\z/
        handle_quote_confirm_no(update, user, $1)
      when /\Aq:rand:(\d+)\z/
        handle_quote_random_callback(update, user)
      when /\Aq:show:(\d+)\z/
        handle_quote_show(update, user, $1.to_i)
      when /\Aq:del:(\d+)\z/
        handle_delete_confirm_callback(update, user, $1.to_i)
      when /\Aq:dely:(\d+)\z/
        handle_quote_delete_yes(update, user, $1.to_i)
      when /\Aq:deln:(\d+)\z/
        handle_quote_delete_no(update, user, $1.to_i)
      when /\Alist:pg:(\d+)\z/
        handle_list_page_callback(update, user, $1.to_i)
      when /\Aset:(.+)\z/
        client.answer_callback_query(callback_query_id: update.callback_query_id, text: "🚧 Coming soon!")
      end
    end

    def handle_start(update, user)
      client.send_message(
        chat_id: update.chat_id,
        text: "👋 Welcome to *QuoterBack*, #{user.first_name || 'friend'}!\n\nSend me any quote you love and I'll save it for you. You can get a random one back anytime with /quote.\n\nFirst, let's set your timezone so I can deliver quotes at the right time.",
        reply_markup: {
          inline_keyboard: [ [
            { text: "🌍 Set my timezone", callback_data: "ob:tz" }
          ], [
            { text: "⏭ Skip for now", callback_data: "ob:help" }
          ] ]
        }
      )
    end

    def handle_ping(update)
      client.send_message(chat_id: update.chat_id, text: "🏓 Pong!")
    end

    def handle_add(update, user, text)
      if text.present?
        user.quotes.create!(content: text)
        count = user.quotes.count
        client.send_message(
          chat_id: update.chat_id,
          text: "✅ Saved (quote #{count} in your collection)"
        )
      else
        user.update!(state: "awaiting_quote_text")
        client.send_message(
          chat_id: update.chat_id,
          text: "📝 OK, send me the quote text now."
        )
      end
    end

    def handle_awaiting_quote_text(update, user, text)
      user.quotes.create!(content: text)
      user.update!(state: nil)
      count = user.quotes.count
      client.send_message(
        chat_id: update.chat_id,
        text: "✅ Saved (quote #{count} in your collection)"
      )
    end

    def handle_confirm_on_text(update, user, text)
      token = SecureRandom.hex(8)
      Rails.cache.write(
        "pending_quote:#{token}",
        { from_id: update.from_id, chat_id: update.chat_id, text: text },
        expires_in: 10.minutes
      )
      client.send_message(
        chat_id: update.chat_id,
        text: "💬 Add this as a quote?\n\n\"#{text.truncate(300)}\"",
        reply_markup: {
          inline_keyboard: [ [
            { text: "✅ Add as quote", callback_data: "qc:yes:#{token}" },
            { text: "❌ Not a quote", callback_data: "qc:no:#{token}" }
          ] ]
        }
      )
    end

    def handle_quote_confirm_yes(update, user, token)
      entry = Rails.cache.read("pending_quote:#{token}")

      if entry.nil?
        client.answer_callback_query(callback_query_id: update.callback_query_id, text: "")
        client.send_message(chat_id: update.chat_id,
          text: "⏰ That quote expired — please send it again.")
        return
      end

      unless entry[:from_id] == update.from_id
        client.answer_callback_query(callback_query_id: update.callback_query_id,
          text: "This isn't your quote confirmation.")
        return
      end

      client.answer_callback_query(callback_query_id: update.callback_query_id, text: "")

      quote = user.quotes.create!(content: entry[:text])
      Rails.cache.delete("pending_quote:#{token}")

      count = user.quotes.count
      is_first = count == 1

      success_text = "✅ Saved (quote #{count} in your collection)"
      success_text += "\n\n💡 Want one delivered daily? Set a schedule!" if is_first

      client.edit_message_text(
        chat_id: update.chat_id,
        message_id: update.message_id,
        text: success_text,
        reply_markup: {
          inline_keyboard: [ [
            { text: "🗑 Undo", callback_data: "q:del:#{quote.id}" }
          ] ]
        }
      )
    rescue ActiveRecord::RecordInvalid => e
      client.send_message(chat_id: update.chat_id, text: "❌ Couldn't save: #{e.message}")
    end

    def handle_quote_confirm_no(update, user, token)
      Rails.cache.delete("pending_quote:#{token}")
      client.answer_callback_query(callback_query_id: update.callback_query_id, text: "👍 Dismissed")
    end

    def handle_quote(update, user)
      quote = Quote.random_for(user)

      if quote.nil?
        client.send_message(
          chat_id: update.chat_id,
          text: "📭 You have no quotes yet! Send me any text and I'll save it for you.",
          reply_markup: { inline_keyboard: [ [ { text: "📥 How to add quotes", callback_data: "ob:help" } ] ] }
        )
        return
      end

      presenter = Bot::QuotePresenter.new(quote)
      client.send_message(
        chat_id: update.chat_id,
        text: presenter.message_text,
        reply_markup: {
          inline_keyboard: [ [
            { text: "🏷 Tag", callback_data: "q:tag:#{quote.id}" },
            { text: "❤️ Fav", callback_data: "fav:toggle:#{quote.id}" },
            { text: "🗑", callback_data: "q:del:#{quote.id}" }
          ], [
            { text: "🎲 Another", callback_data: "q:rand:0" }
          ] ]
        }
      )

      user.quote_deliveries.create!(
        quote: quote,
        local_date: local_date_for(user),
        context: "on_demand",
        delivered_at: Time.current
      )
      quote.update!(times_delivered: quote.times_delivered + 1, last_delivered_at: Time.current)
    end

    def handle_quote_random_callback(update, user)
      quote = Quote.random_for(user)
      return unless quote

      presenter = Bot::QuotePresenter.new(quote)
      client.edit_message_text(
        chat_id: update.chat_id,
        message_id: update.message_id,
        text: presenter.message_text,
        reply_markup: {
          inline_keyboard: [ [
            { text: "🏷 Tag", callback_data: "q:tag:#{quote.id}" },
            { text: "❤️ Fav", callback_data: "fav:toggle:#{quote.id}" },
            { text: "🗑", callback_data: "q:del:#{quote.id}" }
          ], [
            { text: "🎲 Another", callback_data: "q:rand:0" }
          ] ]
        }
      )

      user.quote_deliveries.create!(
        quote: quote,
        local_date: local_date_for(user),
        context: "on_demand",
        delivered_at: Time.current
      )
      quote.update!(times_delivered: quote.times_delivered + 1, last_delivered_at: Time.current)
    end

    def handle_quote_show(update, user, quote_id)
      quote = user.quotes.find_by(id: quote_id)
      return unless quote

      presenter = Bot::QuotePresenter.new(quote)
      client.edit_message_text(
        chat_id: update.chat_id,
        message_id: update.message_id,
        text: presenter.message_text,
        reply_markup: {
          inline_keyboard: [ [
            { text: "🏷 Tag", callback_data: "q:tag:#{quote.id}" },
            { text: "❤️ Fav", callback_data: "fav:toggle:#{quote.id}" },
            { text: "🗑", callback_data: "q:del:#{quote.id}" }
          ], [
            { text: "🔙 Back to list", callback_data: "list:pg:1" }
          ] ]
        }
      )
    end

    def handle_list(update, user, page: 1)
      quotes = user.quotes.order(created_at: :asc)
      total = quotes.count

      if total == 0
        client.send_message(
          chat_id: update.chat_id,
          text: "📭 You have no quotes yet! Send me any text and I'll save it for you.",
          reply_markup: { inline_keyboard: [ [ { text: "📥 How to add", callback_data: "ob:help" } ] ] }
        )
        return
      end

      total_pages = (total.to_f / PAGE_SIZE).ceil
      page = [ [ page, 1 ].max, total_pages ].min
      offset = (page - 1) * PAGE_SIZE
      page_quotes = quotes.offset(offset).limit(PAGE_SIZE).to_a

      lines = page_quotes.each_with_index.map do |q, i|
        num = offset + i + 1
        preview = q.content.truncate(80)
        "#{num}. #{preview}"
      end

      text = "📋 *Your Quotes* (#{total} total)\n\n#{lines.join("\n\n")}"

      number_buttons = page_quotes.each_with_index.map do |q, i|
        { text: "#{offset + i + 1}", callback_data: "q:show:#{q.id}" }
      end

      nav = []
      nav << { text: "⬅️", callback_data: "list:pg:#{page - 1}" } if page > 1
      nav << { text: "#{page}/#{total_pages}", callback_data: "list:pg:#{page}" }
      nav << { text: "➡️", callback_data: "list:pg:#{page + 1}" } if page < total_pages

      keyboard = [ number_buttons, nav, [ { text: "🎲 Random", callback_data: "q:rand:0" } ] ]

      client.send_message(
        chat_id: update.chat_id,
        text: text,
        reply_markup: { inline_keyboard: keyboard }
      )
    end

    def handle_list_page_callback(update, user, page)
      quotes = user.quotes.order(created_at: :asc)
      total = quotes.count
      return if total == 0

      total_pages = (total.to_f / PAGE_SIZE).ceil
      page = [ [ page, 1 ].max, total_pages ].min
      offset = (page - 1) * PAGE_SIZE
      page_quotes = quotes.offset(offset).limit(PAGE_SIZE).to_a

      lines = page_quotes.each_with_index.map do |q, i|
        num = offset + i + 1
        preview = q.content.truncate(80)
        "#{num}. #{preview}"
      end

      text = "📋 *Your Quotes* (#{total} total)\n\n#{lines.join("\n\n")}"

      number_buttons = page_quotes.each_with_index.map do |q, i|
        { text: "#{offset + i + 1}", callback_data: "q:show:#{q.id}" }
      end

      nav = []
      nav << { text: "⬅️", callback_data: "list:pg:#{page - 1}" } if page > 1
      nav << { text: "#{page}/#{total_pages}", callback_data: "list:pg:#{page}" }
      nav << { text: "➡️", callback_data: "list:pg:#{page + 1}" } if page < total_pages

      keyboard = [ number_buttons, nav, [ { text: "🎲 Random", callback_data: "q:rand:0" } ] ]

      client.edit_message_text(
        chat_id: update.chat_id,
        message_id: update.message_id,
        text: text,
        reply_markup: { inline_keyboard: keyboard }
      )
    end

    def handle_delete_command(update, user, id_str)
      return handle_list(update, user) if id_str.blank?

      quote = user.quotes.find_by(id: id_str.to_i)
      if quote.nil?
        client.send_message(
          chat_id: update.chat_id,
          text: "🤷 That quote's no longer here.",
          reply_markup: { inline_keyboard: [ [ { text: "📋 See your list", callback_data: "list:pg:1" } ] ] }
        )
        return
      end

      client.send_message(
        chat_id: update.chat_id,
        text: "🗑 Delete this quote?\n\n\"#{quote.content.truncate(200)}\"",
        reply_markup: {
          inline_keyboard: [ [
            { text: "🗑 Yes, delete", callback_data: "q:dely:#{quote.id}" },
            { text: "Cancel", callback_data: "q:deln:#{quote.id}" }
          ] ]
        }
      )
    end

    def handle_delete_confirm_callback(update, user, quote_id)
      quote = user.quotes.find_by(id: quote_id)
      if quote.nil?
        client.edit_message_text(
          chat_id: update.chat_id,
          message_id: update.message_id,
          text: "🤷 That quote's no longer here."
        )
        return
      end

      client.edit_message_text(
        chat_id: update.chat_id,
        message_id: update.message_id,
        text: "🗑 Delete this quote?\n\n\"#{quote.content.truncate(200)}\"",
        reply_markup: {
          inline_keyboard: [ [
            { text: "🗑 Yes, delete", callback_data: "q:dely:#{quote.id}" },
            { text: "Cancel", callback_data: "q:deln:#{quote.id}" }
          ] ]
        }
      )
    end

    def handle_quote_delete_yes(update, user, quote_id)
      quote = user.quotes.find_by(id: quote_id)
      quote&.destroy
      client.edit_message_text(
        chat_id: update.chat_id,
        message_id: update.message_id,
        text: "✅ Quote deleted."
      )
    end

    def handle_quote_delete_no(update, user, quote_id)
      client.edit_message_text(
        chat_id: update.chat_id,
        message_id: update.message_id,
        text: "👍 Kept."
      )
    end

    def handle_settings(update, user)
      quote_count = user.quotes.count
      tz_display = user.timezone.present? ? user.timezone : "not set"
      schedule_count = user.delivery_schedules.where(enabled: true).count

      text = "⚙️ *Settings*\n\n" \
             "Quotes: #{quote_count} · TZ: #{tz_display} · Schedules: #{schedule_count}"

      client.send_message(
        chat_id: update.chat_id,
        text: text,
        reply_markup: {
          inline_keyboard: [
            [ { text: "🌍 Timezone", callback_data: "set:tz" },
             { text: "⏰ Schedules", callback_data: "set:sched" } ],
            [ { text: "🏷 Tags", callback_data: "set:tags" },
             { text: "📊 Stats", callback_data: "set:stats" } ],
            [ { text: "📥 Import", callback_data: "set:import" } ]
          ]
        }
      )
    end

    def handle_help(update, user)
      text = "📖 *QuoterBack Help*\n\n" \
             "*Capture*\n" \
             "Just send me any text → I'll ask if it's a quote\n" \
             "/add — add a quote\n\n" \
             "*Browse*\n" \
             "/quote — random quote\n" \
             "/list — browse your collection\n\n" \
             "*Deliver*\n" \
             "/schedule — set daily delivery time\n" \
             "/settimezone — set your timezone\n\n" \
             "*Manage*\n" \
             "/settings — your settings & stats\n" \
             "/delete [id] — delete a quote"

      client.send_message(
        chat_id: update.chat_id,
        text: text,
        reply_markup: {
          inline_keyboard: [ [
            { text: "🎲 Random quote", callback_data: "q:rand:0" },
            { text: "📋 Browse", callback_data: "list:pg:1" }
          ] ]
        }
      )
    end

    def handle_schedule_ping(update)
      minutes = update.text.match(/(\d+)\s*min/i)&.captures&.first&.to_i
      minutes ||= 1

      PingJob.set(wait: minutes.minutes).perform_later(update.chat_id, minutes)

      client.send_message(
        chat_id: update.chat_id,
        text: "⏱ I'll ping you back in #{minutes} minute#{"s" if minutes != 1}!"
      )
    end

    def local_date_for(user)
      return Date.current unless user.timezone.present?
      Time.current.in_time_zone(user.timezone).to_date
    end
  end
end
