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

      # /cancel always escapes any state
      if text.downcase == "/cancel"
        if user.state.present?
          user.update!(state: nil)
          client.send_message(chat_id: update.chat_id, text: "👍 Cancelled.")
        else
          schedules = user.delivery_schedules.where(enabled: true)
          if schedules.any?
            schedules.each do |sched|
              QuoteScheduler.cancel_pending_for(sched)
              sched.update!(enabled: false)
            end
            client.send_message(chat_id: update.chat_id, text: "⏹ Daily delivery stopped.")
          else
            client.send_message(chat_id: update.chat_id, text: "You don't have an active schedule.")
          end
        end
        return
      end

      # State machine takes priority over commands (except /cancel above)
      case user.state
      when "awaiting_timezone"
        return handle_awaiting_timezone_input(update, user, text) unless text.start_with?("/")
      when "awaiting_quote_text"
        return handle_awaiting_quote_text(update, user, text) unless text.start_with?("/")
      when "awaiting_tag_name"
        return handle_awaiting_tag_name(update, user, text) unless text.start_with?("/")
      end

      command, rest = text.split(/\s+/, 2)

      case command.downcase
      when "/start"                        then handle_start(update, user, rest.presence)
      when "/ping"                         then handle_ping(update)
      when "/add"                          then handle_add(update, user, rest)
      when "/quote", "/random"             then handle_quote(update, user, tag_arg: rest)
      when "/list", "/quotes"              then handle_list(update, user, tag_arg: rest)
      when "/timezones"                    then handle_timezones(update, user)
      when "/delete"                       then handle_delete_command(update, user, rest)
      when "/settings"                     then handle_settings(update, user)
      when "/help"                         then handle_help(update, user)
      when "/settimezone", "/timezone"     then handle_settimezone(update, user, rest)
      when "/schedule"                     then handle_schedule_command(update, user, rest)
      when "/cancel"                       then # already handled above
      else
        if text.match?(/ping me in/i)
          return handle_schedule_ping(update)
        end
        handle_confirm_on_text(update, user, text) unless text.start_with?("/")
      end
    end

    def handle_callback(update, user)
      data = update.callback_data.to_s

      case data
      when /\Aob:tz\z/
        client.answer_callback_query(callback_query_id: update.callback_query_id, text: "")
        show_timezone_picker(update, user)
      when /\Aob:help\z/
        client.answer_callback_query(callback_query_id: update.callback_query_id, text: "")
        handle_help(update, user)
      when /\Aob:addfirst\z/
        client.answer_callback_query(callback_query_id: update.callback_query_id, text: "")
        user.update!(state: "awaiting_quote_text")
        client.send_message(
          chat_id: update.chat_id,
          text: "✍️ Send me your first quote — any text you want to save!"
        )
      when /\Aqc:yes:(.+)\z/
        handle_quote_confirm_yes(update, user, $1)
      when /\Aqc:no:(.+)\z/
        handle_quote_confirm_no(update, user, $1)
      when /\Aq:rand:(\d+)\z/
        handle_quote_random_callback(update, user)
      when /\Aq:show:(\d+)\z/
        client.answer_callback_query(callback_query_id: update.callback_query_id, text: "")
        handle_quote_show(update, user, $1.to_i)
      when /\Aq:del:(\d+)\z/
        client.answer_callback_query(callback_query_id: update.callback_query_id, text: "")
        handle_delete_confirm_callback(update, user, $1.to_i)
      when /\Aq:tag:(\d+)\z/
        client.answer_callback_query(callback_query_id: update.callback_query_id, text: "")
        handle_tag_picker(update, user, $1.to_i)
      when /\Atag:add:(\d+):(\d+)\z/
        handle_tag_add(update, user, quote_id: $1.to_i, tag_id: $2.to_i)
      when /\Atag:rm:(\d+):(\d+)\z/
        handle_tag_remove(update, user, quote_id: $1.to_i, tag_id: $2.to_i)
      when /\Atag:new:(\d+)\z/
        handle_tag_new(update, user, $1.to_i)
      when /\Afav:toggle:(\d+)\z/
        handle_fav_toggle(update, user, $1.to_i)
      when /\Aq:bytag:(\d+)\z/
        tag = user.tags.find_by(id: $1.to_i)
        client.answer_callback_query(callback_query_id: update.callback_query_id, text: "")
        if tag
          handle_quote(update, user, tag_arg: "##{tag.name}")
        else
          handle_quote(update, user)
        end
      when /\Aq:dely:(\d+)\z/
        handle_quote_delete_yes(update, user, $1.to_i)
      when /\Aq:deln:(\d+)\z/
        handle_quote_delete_no(update, user, $1.to_i)
      when /\Alist:pg:(\d+)(?::(\d+))?\z/
        handle_list_page_callback(update, user, $1.to_i, $2&.to_i)
      when /\Alist:noop\z/
        client.answer_callback_query(callback_query_id: update.callback_query_id, text: "")
      when /\Atz:idx:(\d+)\z/
        handle_tz_idx_callback(update, user, $1.to_i)
      when /\Atz:type\z/
        client.answer_callback_query(callback_query_id: update.callback_query_id, text: "")
        user.update!(state: "awaiting_timezone")
        client.send_message(chat_id: update.chat_id, text: "⌨️ Type your city, country, or UTC offset (e.g. London, +9, UTC-5):")
      when /\Aset:(.+)\z/
        client.answer_callback_query(callback_query_id: update.callback_query_id, text: "🚧 Coming soon!")
      else
        Rails.logger.debug("[Bot::Dispatcher] unhandled callback: #{data.inspect}")
        client.answer_callback_query(callback_query_id: update.callback_query_id, text: "")
      end
    end

    def handle_start(update, user, payload = nil)
      user.update!(state: "new") unless user.state == "ready"

      greeting = user.first_name.present? ? "Hey #{user.first_name}!" : "Hey there!"

      client.send_message(
        chat_id: update.chat_id,
        text: "👋 #{greeting} Welcome to *QuoterBack* — your personal quote collection.\n\n" \
              "Send me any quote you love and I'll save it. Get it back any time, or have me send one every day.\n\n" \
              "Let's start by setting your timezone so I deliver at the right time for you.",
        reply_markup: {
          inline_keyboard: [
            [ { text: "🌍 Set my timezone", callback_data: "ob:tz" } ],
            [ { text: "✍️ Add my first quote", callback_data: "ob:addfirst" } ],
            [ { text: "❓ How it works", callback_data: "ob:help" } ]
          ]
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

    def handle_quote(update, user, tag_arg: nil)
      tag = nil
      if tag_arg.present?
        raw = tag_arg.strip
        if raw.start_with?("#")
          tag_name = raw.sub(/\A#+/, "").downcase.gsub(/\s+/, "_")
          tag = user.tags.find_by(name: tag_name)
          if tag.nil?
            client.send_message(
              chat_id: update.chat_id,
              text: "🏷 You have no quotes tagged ##{tag_name} yet."
            )
            return
          end
        else
          tag = user.tags.find_by(name: raw.downcase)
          # if no match, tag stays nil and we fall back to random (N11)
        end
      end
      quote = Quote.random_for(user, tag: tag)

      if quote.nil?
        if tag
          client.send_message(
            chat_id: update.chat_id,
            text: "🏷 You have no quotes tagged ##{tag.name} yet."
          )
        else
          client.send_message(
            chat_id: update.chat_id,
            text: "📭 You have no quotes yet! Send me any text and I'll save it for you.",
            reply_markup: { inline_keyboard: [ [ { text: "📥 How to add quotes", callback_data: "ob:help" } ] ] }
          )
        end
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
            { text: "🗑 Delete", callback_data: "q:del:#{quote.id}" }
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

      if quote.nil?
        client.answer_callback_query(callback_query_id: update.callback_query_id, text: "No quotes yet!")
        return
      end

      client.answer_callback_query(callback_query_id: update.callback_query_id, text: "")
      presenter = Bot::QuotePresenter.new(quote)
      client.edit_message_text(
        chat_id: update.chat_id,
        message_id: update.message_id,
        text: presenter.message_text,
        reply_markup: {
          inline_keyboard: [ [
            { text: "🏷 Tag", callback_data: "q:tag:#{quote.id}" },
            { text: "❤️ Fav", callback_data: "fav:toggle:#{quote.id}" },
            { text: "🗑 Delete", callback_data: "q:del:#{quote.id}" }
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
            { text: "🗑 Delete", callback_data: "q:del:#{quote.id}" }
          ], [
            { text: "🔙 Back to list", callback_data: "list:pg:1" }
          ] ]
        }
      )
    end

    def handle_list(update, user, tag_arg: nil, page: 1)
      tag = resolve_list_tag(update, user, tag_arg)
      return if tag == :not_found

      render_list(update, user, page: page, tag: tag, edit: false)
    end

    def handle_list_page_callback(update, user, page, tag_id = nil)
      client.answer_callback_query(callback_query_id: update.callback_query_id, text: "")
      tag = tag_id ? user.tags.find_by(id: tag_id) : nil
      render_list(update, user, page: page, tag: tag, edit: true)
    end

    # Resolves a /list tag argument. Returns the Tag, nil (no filter), or
    # :not_found (an explicit #tag with no match — caller should bail).
    def resolve_list_tag(update, user, tag_arg)
      return nil if tag_arg.blank?

      raw = tag_arg.strip
      if raw.start_with?("#")
        tag_name = raw.sub(/\A#+/, "").downcase.gsub(/\s+/, "_")
        tag = user.tags.find_by(name: tag_name)
        if tag.nil?
          client.send_message(chat_id: update.chat_id, text: "🏷 You have no quotes tagged ##{tag_name} yet.")
          return :not_found
        end
        tag
      else
        # Bare word: filter only on an exact tag hit, else no filter (N11)
        user.tags.find_by(name: raw.downcase)
      end
    end

    def render_list(update, user, page:, tag:, edit:)
      quotes = if tag
        user.quotes.joins(:taggings).where(taggings: { tag_id: tag.id }).order(created_at: :asc)
      else
        user.quotes.order(created_at: :asc)
      end
      total = quotes.count

      if total == 0
        empty_text = tag ? "🏷 You have no quotes tagged ##{tag.name} yet." : "📭 You have no quotes yet! Send me any text and I'll save it for you."
        markup = { inline_keyboard: [ [ { text: "📥 How to add", callback_data: "ob:help" } ] ] }
        if edit
          client.edit_message_text(chat_id: update.chat_id, message_id: update.message_id, text: empty_text, reply_markup: markup)
        else
          client.send_message(chat_id: update.chat_id, text: empty_text, reply_markup: markup)
        end
        return
      end

      total_pages = (total.to_f / PAGE_SIZE).ceil
      page = [ [ page, 1 ].max, total_pages ].min
      offset = (page - 1) * PAGE_SIZE
      page_quotes = quotes.offset(offset).limit(PAGE_SIZE).to_a

      lines = page_quotes.each_with_index.map do |q, i|
        num = offset + i + 1
        "#{num}. #{q.content.truncate(80)}"
      end

      header = tag ? "📋 *Quotes tagged ##{tag.name}* (#{total} total)" : "📋 *Your Quotes* (#{total} total)"
      text = "#{header}\n\n#{lines.join("\n\n")}"

      # Carry the tag filter through pagination via the trailing :<tag_id> segment
      tag_suffix = tag ? ":#{tag.id}" : ""

      number_buttons = page_quotes.each_with_index.map do |q, i|
        { text: "#{offset + i + 1}", callback_data: "q:show:#{q.id}" }
      end
      # Telegram caps inline-keyboard rows at 8 buttons; split into rows of 5 (C1).
      number_rows = number_buttons.each_slice(5).to_a

      nav = []
      nav << { text: "⬅️", callback_data: "list:pg:#{page - 1}#{tag_suffix}" } if page > 1
      nav << { text: "#{page}/#{total_pages}", callback_data: "list:noop" }
      nav << { text: "➡️", callback_data: "list:pg:#{page + 1}#{tag_suffix}" } if page < total_pages

      keyboard = [ *number_rows, nav, [ { text: "🎲 Random", callback_data: "q:rand:0" } ] ]

      if edit
        client.edit_message_text(chat_id: update.chat_id, message_id: update.message_id, text: text, reply_markup: { inline_keyboard: keyboard })
      else
        client.send_message(chat_id: update.chat_id, text: text, reply_markup: { inline_keyboard: keyboard })
      end
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
      client.answer_callback_query(callback_query_id: update.callback_query_id, text: "🗑 Deleted")
      client.edit_message_text(
        chat_id: update.chat_id,
        message_id: update.message_id,
        text: "✅ Quote deleted."
      )
    end

    def handle_quote_delete_no(update, user, quote_id)
      client.answer_callback_query(callback_query_id: update.callback_query_id, text: "👍 Kept")
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

    def handle_settimezone(update, user, tz_input)
      if tz_input.present?
        apply_timezone(update, user, tz_input)
      else
        show_timezone_picker(update, user)
      end
    end

    def show_timezone_picker(update, user)
      zones = Bot::TimezoneParser.common_zones
      cache_key = "tz_picker:#{update.chat_id}"
      Rails.cache.write(cache_key, zones.map(&:name), expires_in: 10.minutes)

      buttons = zones.each_with_index.map do |zone, i|
        now = Time.current.in_time_zone(zone)
        [ { text: "#{zone.name} (#{now.strftime('%H:%M')})", callback_data: "tz:idx:#{i}" } ]
      end
      buttons << [ { text: "⌨️ Type city or UTC offset", callback_data: "tz:type" } ]

      client.send_message(
        chat_id: update.chat_id,
        text: "🌍 Choose your timezone:",
        reply_markup: { inline_keyboard: buttons }
      )
    end

    def apply_timezone(update, user, tz_input)
      tz = Bot::TimezoneParser.parse(tz_input)
      if tz.nil?
        # Re-show the picker with an error message — never a bare text dead-end
        show_timezone_picker(update, user)
        client.send_message(
          chat_id: update.chat_id,
          text: "❓ Couldn't recognize \"#{tz_input.truncate(40)}\". Try a city name, IANA zone (e.g. Europe/London), or offset like +9."
        )
        return
      end

      old_timezone = user.timezone
      user.update!(timezone: tz.tzinfo.name, state: nil)

      local_now = Time.current.in_time_zone(tz)

      if old_timezone.nil?
        client.send_message(
          chat_id: update.chat_id,
          text: "✅ You're all set! Timezone: *#{tz.name}* (local #{local_now.strftime('%H:%M')}).\n\n" \
                "Now send me any quote you love and I'll save it for you. Tap ☰ Menu anytime to see commands.",
          reply_markup: {
            inline_keyboard: [ [
              { text: "✍️ Add my first quote", callback_data: "ob:addfirst" },
              { text: "📖 Show commands", callback_data: "ob:help" }
            ] ]
          }
        )
      else
        client.send_message(
          chat_id: update.chat_id,
          text: "✅ Timezone updated to *#{tz.name}* (#{local_now.strftime('%Z %z')}, local time #{local_now.strftime('%H:%M')})."
        )
      end

      reschedule_all_for(user) if old_timezone != tz.tzinfo.name
    end

    def handle_awaiting_timezone_input(update, user, text)
      apply_timezone(update, user, text)
    end

    def handle_tz_idx_callback(update, user, idx)
      cache_key = "tz_picker:#{update.chat_id}"
      zone_names = Rails.cache.read(cache_key)

      unless zone_names && zone_names[idx]
        client.answer_callback_query(callback_query_id: update.callback_query_id, text: "")
        show_timezone_picker(update, user)
        return
      end

      client.answer_callback_query(callback_query_id: update.callback_query_id, text: "")
      apply_timezone(update, user, zone_names[idx])
    end

    def handle_timezones(update, user)
      zones = Bot::TimezoneParser.common_zones
      lines = zones.map do |tz|
        now = Time.current.in_time_zone(tz)
        "#{tz.name} — #{now.strftime('%H:%M')} (#{now.strftime('%Z')})"
      end

      client.send_message(
        chat_id: update.chat_id,
        text: "🌍 *Common timezones:*\n\n#{lines.join("\n")}\n\nUse /settimezone <city or offset> to set yours.",
        reply_markup: {
          inline_keyboard: [ [ { text: "🌍 Pick my timezone", callback_data: "ob:tz" } ] ]
        }
      )
    end

    def handle_tag_picker(update, user, quote_id)
      quote = user.quotes.find_by(id: quote_id)
      unless quote
        client.send_message(chat_id: update.chat_id, text: "🤷 That quote's no longer here.")
        return
      end

      user_tags = user.tags.order(:name)
      applied_tag_ids = quote.taggings.pluck(:tag_id).to_set

      buttons = user_tags.map do |tag|
        applied = applied_tag_ids.include?(tag.id)
        action = applied ? "tag:rm:#{quote.id}:#{tag.id}" : "tag:add:#{quote.id}:#{tag.id}"
        label = applied ? "✓ ##{tag.name}" : "##{tag.name}"
        [ { text: label, callback_data: action } ]
      end
      buttons << [ { text: "➕ New tag", callback_data: "tag:new:#{quote.id}" } ]
      buttons << [ { text: "🔙 Back", callback_data: "q:show:#{quote.id}" } ]

      client.send_message(
        chat_id: update.chat_id,
        text: "🏷 Tag this quote:\n\n\"#{quote.content.truncate(100)}\"",
        reply_markup: { inline_keyboard: buttons }
      )
    end

    def handle_tag_add(update, user, quote_id:, tag_id:)
      quote = user.quotes.find_by(id: quote_id)
      tag   = user.tags.find_by(id: tag_id)

      unless quote && tag
        client.answer_callback_query(callback_query_id: update.callback_query_id, text: "Not found.")
        return
      end

      quote.taggings.find_or_create_by!(tag: tag)
      client.answer_callback_query(callback_query_id: update.callback_query_id, text: "✓ Tagged ##{tag.name}")
      handle_tag_picker(update, user, quote_id)
    rescue ActiveRecord::RecordNotUnique
      client.answer_callback_query(callback_query_id: update.callback_query_id, text: "✓ Already tagged")
    end

    def handle_tag_remove(update, user, quote_id:, tag_id:)
      quote = user.quotes.find_by(id: quote_id)
      tag   = user.tags.find_by(id: tag_id)

      unless quote && tag
        client.answer_callback_query(callback_query_id: update.callback_query_id, text: "Not found.")
        return
      end

      quote.taggings.where(tag: tag).destroy_all
      client.answer_callback_query(callback_query_id: update.callback_query_id, text: "✓ Removed ##{tag.name}")
      handle_tag_picker(update, user, quote_id)
    end

    def handle_tag_new(update, user, quote_id)
      quote = user.quotes.find_by(id: quote_id)
      unless quote
        client.answer_callback_query(callback_query_id: update.callback_query_id, text: "Not found.")
        return
      end
      client.answer_callback_query(callback_query_id: update.callback_query_id, text: "")
      Rails.cache.write("pending_tag_quote:#{update.chat_id}", quote_id, expires_in: 10.minutes)
      user.update!(state: "awaiting_tag_name")
      client.send_message(
        chat_id: update.chat_id,
        text: "🏷 Type the tag name (e.g. stoic, motivation):"
      )
    end

    def handle_awaiting_tag_name(update, user, text)
      quote_id = Rails.cache.read("pending_tag_quote:#{update.chat_id}")
      unless quote_id
        user.update!(state: nil)
        client.send_message(chat_id: update.chat_id, text: "Session expired. Please try tagging again.")
        return
      end

      quote = user.quotes.find_by(id: quote_id)
      unless quote
        user.update!(state: nil)
        client.send_message(chat_id: update.chat_id, text: "🤷 That quote's no longer here.")
        return
      end

      raw_name = text.strip
      normalized = raw_name.gsub(/\A#+/, "").downcase.gsub(/\s+/, "_").strip

      if normalized.empty? || normalized !~ /\A[a-z0-9_]+\z/
        client.send_message(chat_id: update.chat_id,
          text: "❌ Tag names can only contain letters, numbers, and underscores. Try again:")
        return
      end

      begin
        tag = user.tags.find_or_create_by!(name: normalized)
      rescue ActiveRecord::RecordNotUnique
        retry
      end

      quote.taggings.find_or_create_by!(tag: tag)
      user.update!(state: nil)
      Rails.cache.delete("pending_tag_quote:#{update.chat_id}")

      client.send_message(
        chat_id: update.chat_id,
        text: "✅ Tagged with *##{tag.name}*",
        reply_markup: {
          inline_keyboard: [ [
            { text: "🏷 Add another tag", callback_data: "q:tag:#{quote.id}" },
            { text: "🔙 Back to quote", callback_data: "q:show:#{quote.id}" }
          ] ]
        }
      )
    end

    def handle_fav_toggle(update, user, quote_id)
      quote = user.quotes.find_by(id: quote_id)
      unless quote
        client.answer_callback_query(callback_query_id: update.callback_query_id, text: "Not found.")
        return
      end

      quote.update!(favourited: !quote.favourited)
      toast = quote.favourited ? "❤️ Favourited" : "🤍 Unfavourited"
      client.answer_callback_query(callback_query_id: update.callback_query_id, text: toast)
    end

    def reschedule_all_for(user)
      user.delivery_schedules.where(enabled: true).each do |schedule|
        QuoteScheduler.schedule_for(schedule)
      rescue => e
        Rails.logger.error("[Dispatcher] reschedule error for schedule #{schedule.id}: #{e.message}")
      end
    end

    def handle_schedule_command(update, user, time_str)
      unless user.timezone.present?
        client.send_message(
          chat_id: update.chat_id,
          text: "🌍 Please set your timezone first with /settimezone before scheduling.",
          reply_markup: { inline_keyboard: [ [ { text: "🌍 Set timezone", callback_data: "ob:tz" } ] ] }
        )
        return
      end

      if time_str.blank?
        client.send_message(
          chat_id: update.chat_id,
          text: "⏰ What time should I send your daily quote?\n\nUse format HH:MM, e.g. /schedule 09:00"
        )
        return
      end

      match = time_str.strip.match(/\A(\d{1,2}):(\d{2})\z/)
      unless match
        client.send_message(chat_id: update.chat_id,
          text: "❓ Couldn't parse that time. Please use HH:MM format, e.g. /schedule 09:00")
        return
      end

      hour   = match[1].to_i
      minute = match[2].to_i

      unless (0..23).include?(hour) && (0..59).include?(minute)
        client.send_message(chat_id: update.chat_id,
          text: "❓ Invalid time. Hour must be 0–23, minute 0–59.")
        return
      end

      schedule = user.delivery_schedules.first_or_initialize
      schedule.assign_attributes(hour: hour, minute: minute, enabled: true)
      schedule.save!

      QuoteScheduler.schedule_for(schedule)

      tz = ActiveSupport::TimeZone[user.timezone]
      local_now = Time.current.in_time_zone(tz)
      client.send_message(
        chat_id: update.chat_id,
        text: "✅ Daily quote scheduled for *#{format('%02d:%02d', hour, minute)}* " \
              "(#{tz.name}, your current time: #{local_now.strftime('%H:%M')}).\n\n" \
              "Use /cancel to stop daily delivery."
      )
    end

    def local_date_for(user)
      return Date.current unless user.timezone.present?
      Time.current.in_time_zone(user.timezone).to_date
    end
  end
end
