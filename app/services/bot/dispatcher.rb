module Bot
  # Routes a normalized ParsedUpdate to the appropriate handler.
  # Keep this class thin — delegate heavy work to service objects and jobs.
  class Dispatcher
    PAGE_SIZE = 10

    # Persistent reply-keyboard labels. A tap sends the label as a plain text
    # message, so we map each to the command it should invoke — buttons and
    # slash commands then share one code path.
    MENU_QUOTE    = "🎲 Quote"
    MENU_LIST     = "📋 My quotes"
    MENU_ADD      = "➕ Add quote"
    MENU_SETTINGS = "⚙️ Settings"
    MENU_HELP     = "📖 Help"

    BUTTON_LABELS = {
      MENU_QUOTE    => "/quote",
      MENU_LIST     => "/list",
      MENU_ADD      => "/add",
      MENU_SETTINGS => "/settings",
      MENU_HELP     => "/help"
    }.freeze

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
      elsif update.photo_file_id
        handle_photo(update, user)
      elsif update.document
        handle_document(update, user)
      else
        handle_unsupported_message(update)
      end
    rescue StandardError => e
      Rails.logger.error("[Bot::Dispatcher] Error: #{e.class} — #{e.message}")
      Rollbar.error(e, chat_id: update&.chat_id)
      # Clear the button spinner so a failed callback tap doesn't hang forever.
      if update&.callback_query_id.present?
        begin
          client.answer_callback_query(
            callback_query_id: update.callback_query_id,
            text: "Something went wrong — try again"
          )
        rescue StandardError
          nil
        end
      end
    end

    private

    attr_reader :client

    def handle_text(update, user)
      text = update.text.strip

      # A tap on the persistent reply keyboard arrives as its label text; remap
      # it to the equivalent command so buttons behave exactly like commands
      # (including escaping conversation states).
      text = BUTTON_LABELS[text] || text

      # In groups Telegram appends @BotName to commands (/quote@MyBot); strip it
      # so command routing matches (M1). Only the first token is a command.
      command = text.split(/\s+/, 2).first.to_s.sub(/@[\w]+\z/i, "")

      # /cancel always escapes any state
      if command.downcase == "/cancel"
        # The schedule builder lives only in the cache (no user.state), so check it
        # too — otherwise /cancel mid-build would falsely report "nothing to cancel"
        # while the builder's buttons stayed live (Fable review #1).
        if user.state.present? || read_sched_builder(update).present?
          user.update!(state: nil) if user.state.present?
          clear_sched_builder(update)
          client.send_message(chat_id: update.chat_id, text: "👍 Cancelled.")
        else
          # /cancel is reserved for aborting the current flow (UX23). Stopping or
          # pausing daily delivery now lives in the /schedules manager, so point
          # the user there rather than silently toggling schedules (M11/G1).
          client.send_message(
            chat_id: update.chat_id,
            text: "🗓 Nothing to cancel. Manage your daily deliveries in /schedules.",
            reply_markup: { inline_keyboard: [ [ { text: "📅 My schedules", callback_data: "set:sched" } ] ] }
          )
        end
        return
      end

      # A text message while we're waiting for a file/photo upload means the user
      # changed their mind — drop the flag (and any target cache) so they aren't
      # stuck, then fall through to normal routing (the text is treated as a
      # command or a quote to save).
      if %w[awaiting_import_file awaiting_image_for_quote].include?(user.state)
        Rails.cache.delete("pending_image_quote:#{update.chat_id}") if user.state == "awaiting_image_for_quote"
        user.update!(state: nil)
      end

      # State machine takes priority over commands (except /cancel above)
      case user.state
      when "awaiting_timezone"
        return handle_awaiting_timezone_input(update, user, text) unless text.start_with?("/")
      when "awaiting_quote_text"
        return handle_awaiting_quote_text(update, user, text) unless text.start_with?("/")
      when "awaiting_quote_text_for_photo"
        return handle_awaiting_quote_text_for_photo(update, user, text) unless text.start_with?("/")
      when "awaiting_tag_name"
        return handle_awaiting_tag_name(update, user, text) unless text.start_with?("/")
      end

      rest = text.split(/\s+/, 2)[1]

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
      when "/menu"                         then handle_menu(update, user)
      when "/settimezone", "/timezone"     then handle_settimezone(update, user, rest)
      when "/schedule"                     then handle_schedule_command(update, user, rest)
      when "/schedules"                    then handle_schedules_command(update, user)
      when "/import"                       then handle_import_command(update, user)
      when "/tags"                         then handle_tags_command(update, user)
      when "/addimage"                     then handle_addimage_command(update, user, rest)
      when "/cancel"                       then # already handled above
      else
        # Anchor at the start so a quote merely containing "ping me in" isn't
        # hijacked by the easter egg (M12).
        if text.match?(/\Aping me in\b/i)
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
      when /\Apc:yes:(.+)\z/
        handle_photo_confirm_yes(update, user, $1)
      when /\Apc:no:(.+)\z/
        handle_photo_confirm_no(update, user, $1)
      when /\Aq:img:(\d+)\z/
        handle_quote_image_request(update, user, $1.to_i)
      when /\Aq:rand:(\d+)\z/
        handle_quote_random_callback(update, user, $1.to_i)
      when /\Aq:show:(\d+)(?::(\d+))?(?::(\d+))?\z/
        client.answer_callback_query(callback_query_id: update.callback_query_id, text: "")
        handle_quote_show(update, user, $1.to_i, page: ($2 || 1).to_i, tag_id: $3&.to_i)
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
      when /\Atag:del:(\d+)\z/
        handle_tag_delete_confirm(update, user, $1.to_i)
      when /\Atag:dely:(\d+)\z/
        handle_tag_delete_yes(update, user, $1.to_i)
      when /\Atag:deln:(\d+)\z/
        handle_tag_delete_no(update, user, $1.to_i)
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
      when /\Aset:tz\z/
        client.answer_callback_query(callback_query_id: update.callback_query_id, text: "")
        show_timezone_picker(update, user)
      when /\Aset:sched\z/
        client.answer_callback_query(callback_query_id: update.callback_query_id, text: "")
        show_schedules_manager(update, user)
      when /\Aset:tags\z/
        client.answer_callback_query(callback_query_id: update.callback_query_id, text: "")
        show_tags_manager(update, user)
      when /\Aset:import\z/
        client.answer_callback_query(callback_query_id: update.callback_query_id, text: "")
        handle_import_command(update, user)
      when /\Asched:new\z/
        handle_schedule_new(update, user)
      when /\Asched:tag:(any|\d+)\z/
        handle_schedule_pick_tag(update, user, $1)
      when /\Asched:h:(\d{1,2})\z/
        handle_schedule_pick_hour(update, user, $1.to_i)
      when /\Asched:m:(\d{1,2})\z/
        handle_schedule_pick_minute(update, user, $1.to_i)
      when /\Asched:create\z/
        handle_schedule_create(update, user)
      when /\Asched:cancel\z/
        handle_schedule_builder_cancel(update, user)
      when /\Asched:edit:(\d+)\z/
        handle_schedule_edit(update, user, $1.to_i)
      when /\Asched:toggle:(\d+)\z/
        handle_schedule_toggle(update, user, $1.to_i)
      when /\Asched:del:(\d+)\z/
        handle_schedule_delete_confirm(update, user, $1.to_i)
      when /\Asched:dely:(\d+)\z/
        handle_schedule_delete_yes(update, user, $1.to_i)
      when /\Asched:deln:(\d+)\z/
        handle_schedule_delete_no(update, user, $1.to_i)
      when /\Aset:(.+)\z/
        client.answer_callback_query(callback_query_id: update.callback_query_id, text: "🚧 Coming soon!")
      else
        Rails.logger.debug("[Bot::Dispatcher] unhandled callback: #{data.inspect}")
        client.answer_callback_query(callback_query_id: update.callback_query_id, text: "")
      end
    end

    def handle_start(update, user, payload = nil)
      user.update!(state: "new") unless user.state == "ready"

      # Reserved deep-link for the future public-sharing feature (plan §18.2.5):
      # acknowledge a q_<public_id> payload so a leaked share link doesn't look
      # broken. Unknown payloads are ignored (M9).
      if payload&.start_with?("q_")
        client.send_message(chat_id: update.chat_id, text: "🔗 Shared quotes are coming soon!")
      end

      greeting = user.first_name.present? ? "Hey #{user.first_name}!" : "Hey there!"

      # Returning user (already onboarded): skip setup, just resurface the
      # persistent action menu so common actions are one tap away.
      if user.timezone.present?
        client.send_message(
          chat_id: update.chat_id,
          text: "👋 #{greeting} Welcome back to QuoterBack. Tap an action below, or send me any text to save it.",
          reply_markup: main_reply_keyboard
        )
        return
      end

      client.send_message(
        chat_id: update.chat_id,
        text: "👋 #{greeting} Welcome to QuoterBack — your personal quote collection.\n\n" \
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

    # Persistent action buttons shown above the text input (ReplyKeyboardMarkup).
    # Once sent it stays visible across messages, giving every user always-on
    # common actions without typing. Labels are remapped to commands in
    # #handle_text via BUTTON_LABELS.
    def main_reply_keyboard
      {
        keyboard: [
          [ { text: MENU_QUOTE }, { text: MENU_LIST } ],
          [ { text: MENU_ADD }, { text: MENU_SETTINGS } ],
          [ { text: MENU_HELP } ]
        ],
        resize_keyboard: true,
        is_persistent: true
      }
    end

    def handle_menu(update, user)
      client.send_message(
        chat_id: update.chat_id,
        text: "📱 Here's your menu — tap an action below, or type / to see every command.",
        reply_markup: main_reply_keyboard
      )
    end

    # A message we don't handle (sticker, voice, video, …). Text, photos, and .txt
    # files are handled elsewhere; tell the user what we accept rather than going
    # silent (M13).
    def handle_unsupported_message(update)
      client.send_message(
        chat_id: update.chat_id,
        text: "📝 Send me text or a photo to save a quote — or a .txt file to import many at once."
      )
    end

    # ── Import from a text file (G5, plan §6.4) ──────────────────────────────────

    def handle_import_command(update, user)
      user.update!(state: "awaiting_import_file")
      client.send_message(
        chat_id: update.chat_id,
        text: "📥 Send me a .txt file with one quote per line and I'll add them all in one go.\n\n" \
              "Up to #{QuoteImporter::MAX_LINES} quotes per file (256 KB max)."
      )
    end

    # A .txt document is unambiguous, so we import it whether or not the user ran
    # /import first (friendlier than forcing the command). The awaiting_import_file
    # state still gives a guided entry point and is cleared here on completion.
    def handle_document(update, user)
      doc = update.document

      unless import_text_file?(doc)
        clear_import_state(user)
        client.send_message(
          chat_id: update.chat_id,
          text: "📄 I can only import plain .txt files (one quote per line) right now."
        )
        return
      end

      # A document interrupts any text-capture flow; drop that state (and its cache)
      # so the user's next message isn't mis-consumed as a tag name or quote (Fable
      # review #8).
      if %w[awaiting_tag_name awaiting_quote_text awaiting_quote_text_for_photo].include?(user.state)
        user.update!(state: nil)
        Rails.cache.delete("pending_tag_quote:#{update.chat_id}")
      end

      # file_size is optional in Telegram's payload; when present it lets us reject
      # early, but the real cap is enforced by max_bytes on the streamed download
      # below (so a metadata-less oversized upload still can't be read wholesale).
      if doc[:file_size].to_i > QuoteImporter::MAX_BYTES
        clear_import_state(user)
        client.send_message(chat_id: update.chat_id, text: "❌ That file is too large — imports are capped at 256 KB.")
        return
      end

      content =
        begin
          client.download_file(doc[:file_id], max_bytes: QuoteImporter::MAX_BYTES)
        rescue TelegramClient::Error => e
          Rails.logger.error("[Bot::Dispatcher] import download failed: #{e.message}")
          nil
        end

      if content.nil? || content.strip.empty?
        clear_import_state(user)
        client.send_message(chat_id: update.chat_id, text: "🤔 I couldn't read that file — please try again.")
        return
      end

      result = QuoteImporter.call(user: user, content: content)
      clear_import_state(user)

      unless result.success?
        client.send_message(chat_id: update.chat_id, text: "❌ #{result.error_message}")
        return
      end

      if result.imported.zero?
        client.send_message(
          chat_id: update.chat_id,
          text: "🤷 No new quotes added — those #{result.skipped} line#{'s' unless result.skipped == 1} were already saved or too short."
        )
        return
      end

      summary = "✅ Imported #{result.imported} quote#{'s' unless result.imported == 1}"
      summary += " (skipped #{result.skipped})" if result.skipped.positive?
      summary += "."
      client.send_message(
        chat_id: update.chat_id,
        text: summary,
        reply_markup: { inline_keyboard: [ [ { text: "📋 My quotes", callback_data: "list:pg:1" } ] ] }
      )
    end

    # ── Image attachments (G4, plan §6.6) ────────────────────────────────────────

    def handle_photo(update, user)
      file_id = update.photo_file_id

      # Attaching a photo to an existing quote (via q:img / awaiting_image_for_quote).
      if user.state == "awaiting_image_for_quote"
        return attach_photo_to_pending_quote(update, user, file_id)
      end

      caption = update.caption.to_s.strip

      if caption.present?
        # Photo + caption: confirm like confirm-on-text, but for a photo.
        token = SecureRandom.hex(8)
        Rails.cache.write(
          "pending_photo_quote:#{token}",
          { from_id: update.from_id, chat_id: update.chat_id, file_id: file_id, caption: caption },
          expires_in: 10.minutes
        )
        client.send_message(
          chat_id: update.chat_id,
          text: "🖼 Add this as a quote with the image?\n\n\"#{caption.truncate(300)}\"",
          reply_markup: { inline_keyboard: [ [
            { text: "✅ Add as quote", callback_data: "pc:yes:#{token}" },
            { text: "❌ Not a quote", callback_data: "pc:no:#{token}" }
          ] ] }
        )
      else
        # Photo, no caption: stash the file_id and ask for the quote text.
        Rails.cache.write(
          "pending_photo:#{update.chat_id}",
          { from_id: update.from_id, file_id: file_id },
          expires_in: 10.minutes
        )
        user.update!(state: "awaiting_quote_text_for_photo")
        client.send_message(
          chat_id: update.chat_id,
          text: "📷 Nice image! Now send me the quote text to go with it."
        )
      end
    end

    def handle_awaiting_quote_text_for_photo(update, user, text)
      entry = Rails.cache.read("pending_photo:#{update.chat_id}")
      if entry.nil? || entry[:from_id] != update.from_id
        user.update!(state: nil)
        client.send_message(chat_id: update.chat_id, text: "⏰ That image expired — please send it again.")
        return
      end

      result = QuoteCreator.call(user: user, content: text, photo_file_id: entry[:file_id])
      unless result.success?
        client.send_message(chat_id: update.chat_id, text: "❌ #{result.error_message} Try again, or /cancel.")
        return
      end

      user.update!(state: nil)
      Rails.cache.delete("pending_photo:#{update.chat_id}")
      AttachQuoteImageJob.perform_later(result.quote.id)

      count = user.quotes.count
      client.send_message(
        chat_id: update.chat_id,
        text: "✅ Saved with your image (quote #{count} in your collection)",
        reply_markup: saved_quote_keyboard(result.quote)
      )
    end

    def handle_photo_confirm_yes(update, user, token)
      entry = Rails.cache.read("pending_photo_quote:#{token}")

      if entry.nil?
        client.answer_callback_query(callback_query_id: update.callback_query_id, text: "")
        client.send_message(chat_id: update.chat_id, text: "⏰ That image expired — please send it again.")
        return
      end

      unless entry[:from_id] == update.from_id
        client.answer_callback_query(callback_query_id: update.callback_query_id, text: "This isn't your quote confirmation.")
        return
      end

      client.answer_callback_query(callback_query_id: update.callback_query_id, text: "")

      result = QuoteCreator.call(user: user, content: entry[:caption], photo_file_id: entry[:file_id])
      unless result.success?
        client.send_message(chat_id: update.chat_id, text: "❌ #{result.error_message}")
        return
      end

      Rails.cache.delete("pending_photo_quote:#{token}")
      AttachQuoteImageJob.perform_later(result.quote.id)

      count = user.quotes.count
      client.edit_message_text(
        chat_id: update.chat_id,
        message_id: update.message_id,
        text: "✅ Saved with your image (quote #{count} in your collection)",
        reply_markup: saved_quote_keyboard(result.quote)
      )
    end

    def handle_photo_confirm_no(update, user, token)
      entry = Rails.cache.read("pending_photo_quote:#{token}")
      if entry && entry[:from_id] != update.from_id
        client.answer_callback_query(callback_query_id: update.callback_query_id, text: "This isn't your quote confirmation.")
        return
      end

      Rails.cache.delete("pending_photo_quote:#{token}")
      client.answer_callback_query(callback_query_id: update.callback_query_id, text: "👍 Dismissed")
    end

    def handle_quote_image_request(update, user, quote_id)
      quote = user.quotes.find_by(id: quote_id)
      unless quote
        client.answer_callback_query(callback_query_id: update.callback_query_id, text: "That quote's no longer here")
        return
      end

      client.answer_callback_query(callback_query_id: update.callback_query_id, text: "")
      begin_image_attach(update, user, quote)
    end

    # Typed power-user fallback for the 📷 button (plan §6.6/§8.5.3): /addimage <id>.
    def handle_addimage_command(update, user, id_str)
      quote = id_str.present? && user.quotes.find_by(id: id_str.to_i)
      unless quote
        client.send_message(
          chat_id: update.chat_id,
          text: "🤷 Couldn't find that quote. Open one from /list and tap 📷 Image instead.",
          reply_markup: { inline_keyboard: [ [ { text: "📋 My quotes", callback_data: "list:pg:1" } ] ] }
        )
        return
      end
      begin_image_attach(update, user, quote)
    end

    def begin_image_attach(update, user, quote)
      Rails.cache.write("pending_image_quote:#{update.chat_id}", quote.id, expires_in: 10.minutes)
      user.update!(state: "awaiting_image_for_quote")
      client.send_message(chat_id: update.chat_id, text: "📷 Send me a photo to attach to this quote.")
    end

    def attach_photo_to_pending_quote(update, user, file_id)
      quote_id = Rails.cache.read("pending_image_quote:#{update.chat_id}")
      quote = quote_id && user.quotes.find_by(id: quote_id)

      unless quote
        user.update!(state: nil)
        client.send_message(chat_id: update.chat_id, text: "🤷 That quote's no longer here.")
        return
      end

      quote.update!(photo_file_id: file_id)
      user.update!(state: nil)
      Rails.cache.delete("pending_image_quote:#{update.chat_id}")
      AttachQuoteImageJob.perform_later(quote.id)

      client.send_message(
        chat_id: update.chat_id,
        text: "✅ Image attached!",
        reply_markup: saved_quote_keyboard(quote)
      )
    end

    def import_text_file?(doc)
      return false if doc.nil?

      name = doc[:file_name].to_s.downcase
      mime = doc[:mime_type].to_s.downcase
      name.end_with?(".txt") || mime == "text/plain"
    end

    def clear_import_state(user)
      user.update!(state: nil) if user.state == "awaiting_import_file"
    end

    # Action row shown on a just-saved quote so the user can tag/fav/delete or
    # jump to browsing without typing (plan UX4). All callbacks carry the id.
    def saved_quote_keyboard(quote)
      {
        inline_keyboard: [
          [
            { text: "🏷 Tag", callback_data: "q:tag:#{quote.id}" },
            { text: "❤️ Fav", callback_data: "fav:toggle:#{quote.id}" },
            { text: "📷 Image", callback_data: "q:img:#{quote.id}" },
            { text: "🗑 Delete", callback_data: "q:del:#{quote.id}" }
          ],
          [
            { text: "🎲 Get a quote", callback_data: "q:rand:0" },
            { text: "📋 My quotes", callback_data: "list:pg:1" }
          ]
        ]
      }
    end

    def handle_add(update, user, text)
      if text.present?
        result = QuoteCreator.call(user: user, content: text)
        if result.success?
          count = user.quotes.count
          client.send_message(
            chat_id: update.chat_id,
            text: "✅ Saved (quote #{count} in your collection)",
            reply_markup: saved_quote_keyboard(result.quote)
          )
        else
          client.send_message(chat_id: update.chat_id, text: "❌ #{result.error_message}")
        end
      else
        user.update!(state: "awaiting_quote_text")
        client.send_message(
          chat_id: update.chat_id,
          text: "📝 OK, send me the quote text now."
        )
      end
    end

    def handle_awaiting_quote_text(update, user, text)
      result = QuoteCreator.call(user: user, content: text)
      unless result.success?
        # Keep the state so the next message is another attempt (or /cancel).
        client.send_message(chat_id: update.chat_id, text: "❌ #{result.error_message} Try again, or /cancel.")
        return
      end

      user.update!(state: nil)
      count = user.quotes.count
      client.send_message(
        chat_id: update.chat_id,
        text: "✅ Saved (quote #{count} in your collection)",
        reply_markup: saved_quote_keyboard(result.quote)
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
          text: "⏰ That quote expired — please send it again.",
          reply_markup: { inline_keyboard: [ [ { text: "✍️ Add a quote", callback_data: "ob:addfirst" } ] ] })
        return
      end

      unless entry[:from_id] == update.from_id
        client.answer_callback_query(callback_query_id: update.callback_query_id,
          text: "This isn't your quote confirmation.")
        return
      end

      client.answer_callback_query(callback_query_id: update.callback_query_id, text: "")

      result = QuoteCreator.call(user: user, content: entry[:text])
      unless result.success?
        client.send_message(chat_id: update.chat_id, text: "❌ #{result.error_message}")
        return
      end

      quote = result.quote
      Rails.cache.delete("pending_quote:#{token}")

      count = user.quotes.count
      is_first = count == 1

      success_text = "✅ Saved (quote #{count} in your collection)"
      success_text += "\n\n💡 Want one delivered daily? Use /schedule to set a daily time." if is_first

      client.edit_message_text(
        chat_id: update.chat_id,
        message_id: update.message_id,
        text: success_text,
        reply_markup: saved_quote_keyboard(quote)
      )
    end

    def handle_quote_confirm_no(update, user, token)
      entry = Rails.cache.read("pending_quote:#{token}")
      # Only the sender who created the pending quote may dismiss it (M7).
      if entry && entry[:from_id] != update.from_id
        client.answer_callback_query(callback_query_id: update.callback_query_id,
          text: "This isn't your quote confirmation.")
        return
      end

      Rails.cache.delete("pending_quote:#{token}")
      client.answer_callback_query(callback_query_id: update.callback_query_id, text: "👍 Dismissed")
    end

    def handle_quote(update, user, tag_arg: nil)
      tag = nil
      if tag_arg.present?
        raw = tag_arg.strip
        if raw.start_with?("#")
          tag_name = Tag.normalize(raw)
          tag = user.tags.find_by(name: tag_name)
          if tag.nil?
            client.send_message(
              chat_id: update.chat_id,
              text: "🏷 You have no quotes tagged ##{tag_name} yet."
            )
            return
          end
        else
          tag = user.tags.find_by(name: Tag.normalize(raw))
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

      keyboard = [
        [
          { text: "🏷 Tag", callback_data: "q:tag:#{quote.id}" },
          { text: "❤️ Fav", callback_data: "fav:toggle:#{quote.id}" },
          { text: "🗑 Delete", callback_data: "q:del:#{quote.id}" }
        ],
        [ { text: "🎲 Another", callback_data: "q:rand:0" } ]
      ]

      # On a bare /quote, offer a row of the user's top tags so they can pick a
      # tag without typing (G3 — wires the q:bytag handler).
      if tag.nil?
        tag_row = top_tags_for(user).map { |t| { text: "##{t.name}", callback_data: "q:bytag:#{t.id}" } }
        keyboard << tag_row if tag_row.any?
      end

      Bot::QuoteMessenger.send_quote(
        client: client,
        chat_id: update.chat_id,
        quote: quote,
        reply_markup: { inline_keyboard: keyboard }
      )

      record_on_demand_delivery(user, quote)
    end

    # Logs a /quote or "Another" tap and bumps the quote's delivery counters.
    def record_on_demand_delivery(user, quote)
      user.quote_deliveries.create!(
        quote: quote,
        local_date: local_date_for(user),
        context: "on_demand",
        delivered_at: Time.current
      )
      quote.update!(times_delivered: quote.times_delivered + 1, last_delivered_at: Time.current)
    end

    # The user's most-used tags (for the bare-/quote picker row, G3).
    def top_tags_for(user, limit: 3)
      user.tags
          .left_joins(:taggings)
          .group("tags.id")
          .order(Arel.sql("COUNT(taggings.id) DESC"))
          .order(:name)
          .limit(limit)
    end

    def handle_quote_random_callback(update, user, schedule_id = 0)
      # "Another" from a scheduled delivery card must stay within that schedule's
      # scope (its tag). schedule_id 0 = on-demand → whole collection (C5).
      tag = nil
      if schedule_id.positive?
        schedule = user.delivery_schedules.find_by(id: schedule_id)
        tag = schedule&.tag
      end

      quote = Quote.random_for(user, tag: tag)

      if quote.nil?
        client.answer_callback_query(callback_query_id: update.callback_query_id, text: "No quotes yet!")
        return
      end

      client.answer_callback_query(callback_query_id: update.callback_query_id, text: "")
      keyboard = {
        inline_keyboard: [ [
          { text: "🏷 Tag", callback_data: "q:tag:#{quote.id}" },
          { text: "❤️ Fav", callback_data: "fav:toggle:#{quote.id}" },
          { text: "🗑 Delete", callback_data: "q:del:#{quote.id}" }
        ], [
          { text: "🎲 Another", callback_data: "q:rand:0" }
        ] ]
      }

      if quote.photo_file_id.present?
        # A text message can't be edited into a photo, so send the next quote as a
        # fresh message when it carries an image.
        Bot::QuoteMessenger.send_quote(client: client, chat_id: update.chat_id, quote: quote, reply_markup: keyboard)
      else
        presenter = Bot::QuotePresenter.new(quote)
        begin
          client.edit_message_text(
            chat_id: update.chat_id,
            message_id: update.message_id,
            text: presenter.message_text,
            reply_markup: keyboard
          )
        rescue TelegramClient::Error
          # The source card was a photo (media) message — you can't edit text into
          # it — so send the text quote as a fresh message instead.
          client.send_message(chat_id: update.chat_id, text: presenter.message_text, reply_markup: keyboard)
        end
      end

      record_on_demand_delivery(user, quote)
    end

    def handle_quote_show(update, user, quote_id, page: 1, tag_id: nil)
      quote = user.quotes.find_by(id: quote_id)
      unless quote
        # Don't leave the tap looking like a no-op (M5).
        client.edit_message_text(
          chat_id: update.chat_id,
          message_id: update.message_id,
          text: "🤷 That quote's no longer here.",
          reply_markup: { inline_keyboard: [ [ { text: "📋 See your list", callback_data: "list:pg:1" } ] ] }
        )
        return
      end

      # Return the user to the exact page and tag filter they came from (M4).
      back_target = "list:pg:#{page}#{tag_id ? ":#{tag_id}" : ''}"

      presenter = Bot::QuotePresenter.new(quote)
      client.edit_message_text(
        chat_id: update.chat_id,
        message_id: update.message_id,
        text: presenter.message_text,
        reply_markup: {
          inline_keyboard: [ [
            { text: "🏷 Tag", callback_data: "q:tag:#{quote.id}" },
            { text: "❤️ Fav", callback_data: "fav:toggle:#{quote.id}" },
            { text: "📷 Image", callback_data: "q:img:#{quote.id}" },
            { text: "🗑 Delete", callback_data: "q:del:#{quote.id}" }
          ], [
            { text: "🔙 Back to list", callback_data: back_target }
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
        tag_name = Tag.normalize(raw)
        tag = user.tags.find_by(name: tag_name)
        if tag.nil?
          client.send_message(chat_id: update.chat_id, text: "🏷 You have no quotes tagged ##{tag_name} yet.")
          return :not_found
        end
        tag
      else
        # Bare word: filter only on an exact tag hit, else no filter (N11)
        user.tags.find_by(name: Tag.normalize(raw))
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

      header = tag ? "📋 Quotes tagged ##{tag.name} (#{total} total)" : "📋 Your Quotes (#{total} total)"
      text = "#{header}\n\n#{lines.join("\n\n")}"

      # Carry the tag filter through pagination via the trailing :<tag_id> segment
      tag_suffix = tag ? ":#{tag.id}" : ""

      number_buttons = page_quotes.each_with_index.map do |q, i|
        # Carry the current page + tag so the detail card can navigate back (M4).
        { text: "#{offset + i + 1}", callback_data: "q:show:#{q.id}:#{page}#{tag_suffix}" }
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

      text = "⚙️ Settings\n\n" \
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
            [ { text: "📥 Import", callback_data: "set:import" } ],
            [ { text: "🎲 Get a quote", callback_data: "q:rand:0" },
             { text: "📋 My quotes", callback_data: "list:pg:1" } ]
          ]
        }
      )
    end

    def handle_help(update, user)
      text = "📖 QuoterBack Help\n\n" \
             "Capture\n" \
             "Just send me any text → I'll ask if it's a quote\n" \
             "Send a photo (with or without a caption) to save an image quote\n" \
             "/add — add a quote\n" \
             "/import — bulk-add from a .txt file\n\n" \
             "Browse\n" \
             "/quote — random quote\n" \
             "/list — browse your collection\n\n" \
             "Deliver\n" \
             "/schedule — set daily delivery time\n" \
             "/schedules — manage your deliveries\n" \
             "/settimezone — set your timezone\n\n" \
             "Manage\n" \
             "/tags — manage your tags\n" \
             "/settings — your settings & stats\n" \
             "/delete [id] — delete a quote"

      client.send_message(
        chat_id: update.chat_id,
        text: text,
        reply_markup: {
          inline_keyboard: [
            [ { text: "🎲 Random quote", callback_data: "q:rand:0" },
             { text: "📋 Browse", callback_data: "list:pg:1" } ],
            [ { text: "✍️ Add a quote", callback_data: "ob:addfirst" },
             { text: "🌍 Timezone", callback_data: "ob:tz" } ]
          ]
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
        # Explain first, then re-show the picker — never a bare text dead-end (M3).
        client.send_message(
          chat_id: update.chat_id,
          text: "❓ Couldn't recognize \"#{tz_input.truncate(40)}\". Try a city name, IANA zone (e.g. Europe/London), or offset like +9."
        )
        show_timezone_picker(update, user)
        return
      end

      old_timezone = user.timezone
      # Setting a timezone completes onboarding — mark the user ready (M10).
      user.update!(timezone: tz.tzinfo.name, state: "ready")

      local_now = Time.current.in_time_zone(tz)

      if old_timezone.nil?
        client.send_message(
          chat_id: update.chat_id,
          text: "✅ You're all set! Timezone: #{tz.name} (local #{local_now.strftime('%H:%M')}).\n\n" \
                "Now send me any quote you love and I'll save it. Use the buttons below anytime — " \
                "or type / to see every command.",
          reply_markup: main_reply_keyboard
        )
      else
        client.send_message(
          chat_id: update.chat_id,
          text: "✅ Timezone updated to #{tz.name} (#{local_now.strftime('%Z %z')}, local time #{local_now.strftime('%H:%M')})."
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
        text: "🌍 Common timezones:\n\n#{lines.join("\n")}\n\nUse /settimezone <city or offset> to set yours.",
        reply_markup: {
          inline_keyboard: [ [ { text: "🌍 Pick my timezone", callback_data: "ob:tz" } ] ]
        }
      )
    end

    def handle_tag_picker(update, user, quote_id, edit: false)
      quote = user.quotes.find_by(id: quote_id)
      unless quote
        client.send_message(chat_id: update.chat_id, text: "🤷 That quote's no longer here.")
        return
      end

      user_tags = user.tags.order(:name).limit(TAG_BUTTON_LIMIT)
      applied_tag_ids = quote.taggings.pluck(:tag_id).to_set

      buttons = user_tags.map do |tag|
        applied = applied_tag_ids.include?(tag.id)
        action = applied ? "tag:rm:#{quote.id}:#{tag.id}" : "tag:add:#{quote.id}:#{tag.id}"
        label = applied ? "✓ ##{tag.name}" : "##{tag.name}"
        [ { text: label, callback_data: action } ]
      end
      buttons << [ { text: "➕ New tag", callback_data: "tag:new:#{quote.id}" } ]
      buttons << [ { text: "🔙 Back", callback_data: "q:show:#{quote.id}" } ]

      text = "🏷 Tag this quote:\n\n\"#{quote.content.truncate(100)}\""
      markup = { inline_keyboard: buttons }

      # Re-renders after a toggle edit the existing message instead of stacking
      # a new picker in the chat (M6). First open (via q:tag) sends fresh.
      if edit
        client.edit_message_text(chat_id: update.chat_id, message_id: update.message_id, text: text, reply_markup: markup)
      else
        client.send_message(chat_id: update.chat_id, text: text, reply_markup: markup)
      end
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
      handle_tag_picker(update, user, quote_id, edit: true)
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
      handle_tag_picker(update, user, quote_id, edit: true)
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

    # ── Tag management: /tags list + delete flow (G6, plan §9.1/§8.5.5) ──────────

    def handle_tags_command(update, user)
      show_tags_manager(update, user)
    end

    # Two buttons per tag row; keep the total well under Telegram's 100-button
    # inline-keyboard cap so a user with many tags still gets a usable manager.
    TAGS_MANAGE_LIMIT = 45

    def show_tags_manager(update, user, edit: false)
      total = user.tags.count

      if total.zero?
        send_or_edit(
          update,
          "🏷 You haven't created any tags yet.\n\nOpen any quote and tap 🏷 Tag to start organizing your collection.",
          { inline_keyboard: [ [ { text: "📋 My quotes", callback_data: "list:pg:1" } ] ] },
          edit: edit
        )
        return
      end

      tags = user.tags
                 .left_joins(:taggings)
                 .group("tags.id")
                 .select("tags.*, COUNT(taggings.id) AS quotes_count")
                 .order("tags.name")
                 .limit(TAGS_MANAGE_LIMIT)
                 .to_a

      lines = tags.map { |t| "##{t.name} — #{t.quotes_count} quote#{'s' unless t.quotes_count == 1}" }
      header = "🏷 Your tags"
      header += " (showing #{TAGS_MANAGE_LIMIT} of #{total})" if total > TAGS_MANAGE_LIMIT
      text = "#{header}\n\n#{lines.join("\n")}"

      keyboard = tags.flat_map do |t|
        [ [
          { text: "🔍 ##{t.name}", callback_data: "list:pg:1:#{t.id}" },
          { text: "🗑", callback_data: "tag:del:#{t.id}" }
        ] ]
      end

      send_or_edit(update, text, { inline_keyboard: keyboard }, edit: edit)
    end

    def handle_tag_delete_confirm(update, user, tag_id)
      tag = user.tags.find_by(id: tag_id)
      unless tag
        client.answer_callback_query(callback_query_id: update.callback_query_id, text: "That tag is gone")
        return show_tags_manager(update, user, edit: true)
      end

      client.answer_callback_query(callback_query_id: update.callback_query_id, text: "")

      # Name the blast radius before deleting (plan §8.5.5): deleting a tag also
      # destroys its tag-scoped delivery schedules. Quotes keep their text.
      schedules = tag.delivery_schedules.order(:hour, :minute)
      warning =
        if schedules.any?
          times = schedules.map { |s| format("%02d:%02d", s.hour, s.minute) }.join(", ")
          "\n\n⚠️ This also removes #{schedules.size} schedule#{'s' unless schedules.size == 1} (#{times})."
        else
          ""
        end

      client.edit_message_text(
        chat_id: update.chat_id,
        message_id: update.message_id,
        text: "🗑 Delete ##{tag.name}? Your quotes keep their text — they just lose this tag.#{warning}",
        reply_markup: { inline_keyboard: [ [
          { text: "🗑 Delete anyway", callback_data: "tag:dely:#{tag.id}" },
          { text: "Cancel", callback_data: "tag:deln:#{tag.id}" }
        ] ] }
      )
    end

    def handle_tag_delete_yes(update, user, tag_id)
      tag = user.tags.find_by(id: tag_id)
      tag&.destroy # cascades taggings + tag-scoped schedules (whose jobs are cancelled)
      client.answer_callback_query(callback_query_id: update.callback_query_id, text: "🗑 Deleted")
      show_tags_manager(update, user, edit: true)
    end

    def handle_tag_delete_no(update, user, tag_id)
      client.answer_callback_query(callback_query_id: update.callback_query_id, text: "👍 Kept")
      show_tags_manager(update, user, edit: true)
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

      normalized = Tag.normalize(text)

      if normalized.length > 30
        client.send_message(chat_id: update.chat_id,
          text: "❌ Tag names must be 30 characters or fewer. Try again:")
        return
      end

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
        text: "✅ Tagged with ##{tag.name}",
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
        Rollbar.error(e, schedule_id: schedule.id)
      end
    end

    # ── Scheduling: builder + manager (G1, plan §9.3) ────────────────────────────
    #
    # `/schedule` (no arg) launches the button-first builder: pick a scope (tag or
    # the whole collection) → pick an hour → pick minutes → confirm. The chosen
    # values accumulate in a short-lived cache entry so no single callback has to
    # carry both tag and time (plan §8/§9.3). `/schedule HH:MM` remains a typed
    # power-user fallback that creates a whole-collection schedule directly.
    # `/schedules` lists every schedule with per-row edit / pause-resume / delete.

    SCHED_BUILDER_TTL = 15.minutes
    SCHED_MINUTES = [ 0, 15, 30, 45 ].freeze

    def handle_schedule_command(update, user, time_str)
      return unless require_timezone(update, user)

      if time_str.blank?
        start_schedule_builder(update, user)
        return
      end

      match = time_str.strip.match(/\A(\d{1,2}):(\d{2})\z/)
      unless match
        client.send_message(chat_id: update.chat_id,
          text: "❓ Couldn't parse that time. Please use HH:MM format, e.g. /schedule 09:00 — or just /schedule to pick from buttons.")
        return
      end

      hour   = match[1].to_i
      minute = match[2].to_i

      unless (0..23).cover?(hour) && (0..59).cover?(minute)
        client.send_message(chat_id: update.chat_id,
          text: "❓ Invalid time. Hour must be 0–23, minute 0–59.")
        return
      end

      if duplicate_schedule(user, hour, minute, nil)
        client.send_message(
          chat_id: update.chat_id,
          text: "📅 You already have a daily delivery at #{format('%02d:%02d', hour, minute)} · Any. Manage it in /schedules.",
          reply_markup: { inline_keyboard: [ [ { text: "📅 My schedules", callback_data: "set:sched" } ] ] }
        )
        return
      end

      schedule = user.delivery_schedules.create!(hour: hour, minute: minute, enabled: true)
      QuoteScheduler.schedule_for(schedule)

      client.send_message(
        chat_id: update.chat_id,
        text: schedule_created_text(user, schedule),
        reply_markup: { inline_keyboard: [ [ { text: "📅 My schedules", callback_data: "set:sched" } ] ] }
      )
    end

    def handle_schedules_command(update, user)
      return unless require_timezone(update, user)
      show_schedules_manager(update, user)
    end

    # Guard shared by every scheduling entry point: delivery is timezone-aware, so
    # a schedule is meaningless until the user has set one.
    def require_timezone(update, user)
      return true if user.timezone.present?

      client.send_message(
        chat_id: update.chat_id,
        text: "🌍 Please set your timezone first with /settimezone before scheduling.",
        reply_markup: { inline_keyboard: [ [ { text: "🌍 Set timezone", callback_data: "ob:tz" } ] ] }
      )
      false
    end

    # ── Builder ──────────────────────────────────────────────────────────────────

    def start_schedule_builder(update, user, edit_id: nil)
      write_sched_builder(update, { edit_id: edit_id })
      show_schedule_tag_chooser(update, user, edit: false)
    end

    def handle_schedule_new(update, user)
      unless user.timezone.present?
        client.answer_callback_query(callback_query_id: update.callback_query_id, text: "Set a timezone first")
        require_timezone(update, user)
        return
      end
      client.answer_callback_query(callback_query_id: update.callback_query_id, text: "")
      # Preserve an in-progress edit target if the user tapped "Change".
      edit_id = read_sched_builder(update)[:edit_id]
      write_sched_builder(update, { edit_id: edit_id })
      show_schedule_tag_chooser(update, user, edit: true)
    end

    # One button per tag (plus Any + Cancel); cap so the keyboard stays under
    # Telegram's 100-button limit for users with many tags (Fable review #2).
    TAG_BUTTON_LIMIT = 90

    def show_schedule_tag_chooser(update, user, edit:)
      buttons = [ [ { text: "🌐 Any (whole collection)", callback_data: "sched:tag:any" } ] ]
      user.tags.order(:name).limit(TAG_BUTTON_LIMIT).each do |tag|
        buttons << [ { text: "##{tag.name}", callback_data: "sched:tag:#{tag.id}" } ]
      end
      buttons << [ { text: "✖️ Cancel", callback_data: "sched:cancel" } ]

      text = "🗓 New daily delivery — which quotes should I send?"
      send_or_edit(update, text, { inline_keyboard: buttons }, edit: edit)
    end

    def handle_schedule_pick_tag(update, user, tag_arg)
      builder = read_sched_builder(update)
      return builder_expired(update) if builder.blank?

      if tag_arg == "any"
        builder[:tag_id] = nil
      else
        tag = user.tags.find_by(id: tag_arg.to_i)
        unless tag
          client.answer_callback_query(callback_query_id: update.callback_query_id, text: "That tag is gone")
          return show_schedule_tag_chooser(update, user, edit: true)
        end
        builder[:tag_id] = tag.id
      end

      write_sched_builder(update, builder)
      client.answer_callback_query(callback_query_id: update.callback_query_id, text: "")
      show_schedule_hour_grid(update)
    end

    def show_schedule_hour_grid(update)
      buttons = (0..23).map { |h| { text: format("%02d", h), callback_data: "sched:h:#{h}" } }
                       .each_slice(6).to_a
      buttons << [ { text: "✖️ Cancel", callback_data: "sched:cancel" } ]
      send_or_edit(update, "🗓 What hour should I deliver? (24-hour clock)", { inline_keyboard: buttons }, edit: true)
    end

    def handle_schedule_pick_hour(update, user, hour)
      builder = read_sched_builder(update)
      return builder_expired(update) if builder.blank?
      # A crafted callback (sched:h:24…99) is a bad value, not an expiry — keep
      # the in-progress builder and just re-show the grid.
      unless (0..23).cover?(hour)
        client.answer_callback_query(callback_query_id: update.callback_query_id, text: "Pick an hour 0–23")
        return show_schedule_hour_grid(update)
      end

      builder[:hour] = hour
      write_sched_builder(update, builder)
      client.answer_callback_query(callback_query_id: update.callback_query_id, text: "")
      show_schedule_minute_chooser(update)
    end

    def show_schedule_minute_chooser(update)
      row = SCHED_MINUTES.map { |m| { text: format(":%02d", m), callback_data: "sched:m:#{m}" } }
      buttons = [ row, [ { text: "✖️ Cancel", callback_data: "sched:cancel" } ] ]
      send_or_edit(update, "🗓 And the minutes?", { inline_keyboard: buttons }, edit: true)
    end

    def handle_schedule_pick_minute(update, user, minute)
      builder = read_sched_builder(update)
      return builder_expired(update) if builder.blank?
      return builder_expired(update) if builder[:hour].nil?
      unless (0..59).cover?(minute)
        client.answer_callback_query(callback_query_id: update.callback_query_id, text: "Pick a valid minute")
        return show_schedule_minute_chooser(update)
      end

      builder[:minute] = minute
      write_sched_builder(update, builder)
      client.answer_callback_query(callback_query_id: update.callback_query_id, text: "")
      show_schedule_confirm(update, user)
    end

    def show_schedule_confirm(update, user)
      builder = read_sched_builder(update)
      return builder_expired(update) if builder.blank? || builder[:hour].nil?

      time  = format("%02d:%02d", builder[:hour], builder[:minute].to_i)
      scope = builder_scope_label(user, builder)
      verb  = builder[:edit_id] ? "Update" : "Create"

      send_or_edit(
        update,
        "📅 Deliver daily at #{time} · #{scope}.\n\nReady?",
        { inline_keyboard: [ [
          { text: "✅ #{verb}", callback_data: "sched:create" },
          { text: "✏️ Change", callback_data: "sched:new" },
          { text: "✖️ Cancel", callback_data: "sched:cancel" }
        ] ] },
        edit: true
      )
    end

    def handle_schedule_create(update, user)
      builder = read_sched_builder(update)
      # Require both hour and minute — a stale/crafted sched:create must not commit
      # a half-built schedule at HH:00 (Fable review #5).
      return builder_expired(update) if builder.blank? || builder[:hour].nil? || builder[:minute].nil?

      hour   = builder[:hour]
      minute = builder[:minute]

      # The edit target may have been deleted (e.g. its tag was removed) while the
      # builder was open — report it rather than silently creating a new row.
      if builder[:edit_id]
        schedule = user.delivery_schedules.find_by(id: builder[:edit_id])
        unless schedule
          clear_sched_builder(update)
          client.answer_callback_query(callback_query_id: update.callback_query_id, text: "That schedule is gone")
          return show_schedules_manager(update, user, edit: true)
        end
      else
        schedule = user.delivery_schedules.new
      end

      # The chosen tag may have been deleted mid-flow — re-open the scope chooser
      # rather than silently downgrading the schedule to the whole collection.
      if builder[:tag_id]
        tag = user.tags.find_by(id: builder[:tag_id])
        unless tag
          client.answer_callback_query(callback_query_id: update.callback_query_id, text: "That tag was removed")
          return show_schedule_tag_chooser(update, user, edit: true)
        end
      else
        tag = nil
      end

      # Don't stack an identical delivery (same time + scope) — it would fire the
      # same quote twice a day. Reusing the manager makes the existing one obvious.
      if duplicate_schedule(user, hour, minute, tag&.id, except_id: schedule.id)
        clear_sched_builder(update)
        client.answer_callback_query(callback_query_id: update.callback_query_id, text: "You already have that delivery")
        return show_schedules_manager(update, user, edit: true)
      end

      # A brand-new schedule starts enabled; editing an existing one must preserve
      # its enabled/paused state so changing a paused schedule's time doesn't
      # silently re-enable it (Fable review #4).
      enabled = schedule.new_record? ? true : schedule.enabled?
      schedule.assign_attributes(hour: hour, minute: minute, tag: tag, enabled: enabled)
      schedule.save!

      if schedule.enabled?
        QuoteScheduler.schedule_for(schedule)
      else
        QuoteScheduler.cancel_pending_for(schedule)
      end

      clear_sched_builder(update)
      client.answer_callback_query(callback_query_id: update.callback_query_id, text: "✅ Saved")
      client.edit_message_text(
        chat_id: update.chat_id,
        message_id: update.message_id,
        text: schedule_saved_text(user, schedule),
        reply_markup: { inline_keyboard: [ [ { text: "📅 My schedules", callback_data: "set:sched" } ] ] }
      )
    end

    def handle_schedule_builder_cancel(update, user)
      clear_sched_builder(update)
      client.answer_callback_query(callback_query_id: update.callback_query_id, text: "Cancelled")
      client.edit_message_text(
        chat_id: update.chat_id,
        message_id: update.message_id,
        text: "🗓 Schedule setup cancelled."
      )
    end

    def builder_expired(update)
      clear_sched_builder(update)
      client.answer_callback_query(callback_query_id: update.callback_query_id, text: "")
      client.send_message(
        chat_id: update.chat_id,
        text: "🗓 That schedule setup expired — start again with /schedule.",
        reply_markup: { inline_keyboard: [ [ { text: "🗓 New schedule", callback_data: "sched:new" } ] ] }
      )
      nil
    end

    # ── Manager ──────────────────────────────────────────────────────────────────

    def show_schedules_manager(update, user, edit: false)
      schedules = user.delivery_schedules.order(:hour, :minute, :id)

      if schedules.empty?
        send_or_edit(
          update,
          "📭 You have no delivery schedules yet.\n\nSet one up and I'll send you a quote every day.",
          { inline_keyboard: [ [ { text: "🗓 New schedule", callback_data: "sched:new" } ] ] },
          edit: edit
        )
        return
      end

      lines = schedules.each_with_index.map do |s, i|
        status = s.enabled? ? "" : " · ⏸ paused"
        "#{i + 1}. #{schedule_label(s)}#{status}"
      end
      text = "📅 Your delivery schedules\n\n#{lines.join("\n")}"

      keyboard = schedules.flat_map do |s|
        toggle = s.enabled? ? { text: "⏸ Pause", callback_data: "sched:toggle:#{s.id}" }
                            : { text: "▶️ Resume", callback_data: "sched:toggle:#{s.id}" }
        [ [
          { text: "✏️ #{schedule_label(s)}", callback_data: "sched:edit:#{s.id}" },
          toggle,
          { text: "🗑", callback_data: "sched:del:#{s.id}" }
        ] ]
      end
      keyboard << [ { text: "➕ New schedule", callback_data: "sched:new" } ]

      send_or_edit(update, text, { inline_keyboard: keyboard }, edit: edit)
    end

    def handle_schedule_edit(update, user, schedule_id)
      schedule = user.delivery_schedules.find_by(id: schedule_id)
      unless schedule
        client.answer_callback_query(callback_query_id: update.callback_query_id, text: "That schedule is gone")
        return show_schedules_manager(update, user, edit: true)
      end

      client.answer_callback_query(callback_query_id: update.callback_query_id, text: "")
      write_sched_builder(update, { edit_id: schedule.id })
      show_schedule_tag_chooser(update, user, edit: true)
    end

    def handle_schedule_toggle(update, user, schedule_id)
      schedule = user.delivery_schedules.find_by(id: schedule_id)
      unless schedule
        client.answer_callback_query(callback_query_id: update.callback_query_id, text: "That schedule is gone")
        return show_schedules_manager(update, user, edit: true)
      end

      if schedule.enabled?
        QuoteScheduler.cancel_pending_for(schedule)
        schedule.update!(enabled: false)
        toast = "⏸ Paused"
      else
        schedule.update!(enabled: true)
        QuoteScheduler.schedule_for(schedule)
        toast = "▶️ Resumed"
      end

      client.answer_callback_query(callback_query_id: update.callback_query_id, text: toast)
      show_schedules_manager(update, user, edit: true)
    end

    def handle_schedule_delete_confirm(update, user, schedule_id)
      schedule = user.delivery_schedules.find_by(id: schedule_id)
      unless schedule
        client.answer_callback_query(callback_query_id: update.callback_query_id, text: "That schedule is gone")
        return show_schedules_manager(update, user, edit: true)
      end

      client.answer_callback_query(callback_query_id: update.callback_query_id, text: "")
      client.edit_message_text(
        chat_id: update.chat_id,
        message_id: update.message_id,
        text: "🗑 Delete this schedule?\n\n📅 #{schedule_label(schedule)}",
        reply_markup: { inline_keyboard: [ [
          { text: "🗑 Yes, delete", callback_data: "sched:dely:#{schedule.id}" },
          { text: "Cancel", callback_data: "sched:deln:#{schedule.id}" }
        ] ] }
      )
    end

    def handle_schedule_delete_yes(update, user, schedule_id)
      schedule = user.delivery_schedules.find_by(id: schedule_id)
      schedule&.destroy # before_destroy cancels the pending job (§7.4)
      client.answer_callback_query(callback_query_id: update.callback_query_id, text: "🗑 Deleted")
      show_schedules_manager(update, user, edit: true)
    end

    def handle_schedule_delete_no(update, user, schedule_id)
      client.answer_callback_query(callback_query_id: update.callback_query_id, text: "👍 Kept")
      show_schedules_manager(update, user, edit: true)
    end

    # ── Scheduling helpers ───────────────────────────────────────────────────────

    # Finds an existing schedule with the same time + scope, so we never stack two
    # identical daily deliveries. `except_id` skips the row being edited.
    def duplicate_schedule(user, hour, minute, tag_id, except_id: nil)
      scope = user.delivery_schedules.where(hour: hour, minute: minute, tag_id: tag_id)
      scope = scope.where.not(id: except_id) if except_id
      scope.exists?
    end

    def schedule_label(schedule)
      time  = format("%02d:%02d", schedule.hour, schedule.minute)
      scope = schedule.tag ? "##{schedule.tag.name}" : "Any"
      "#{time} · #{scope}"
    end

    def builder_scope_label(user, builder)
      return "Any (whole collection)" if builder[:tag_id].nil?
      tag = user.tags.find_by(id: builder[:tag_id])
      tag ? "##{tag.name}" : "Any (whole collection)"
    end

    def schedule_created_text(user, schedule)
      tz = ActiveSupport::TimeZone[user.timezone]
      local_now = Time.current.in_time_zone(tz)
      "✅ Daily quote scheduled — #{schedule_label(schedule)} " \
        "(#{tz.name}, your current time: #{local_now.strftime('%H:%M')}).\n\n" \
        "Manage it any time in /schedules."
    end

    # Confirmation after the builder saves. A paused schedule that was just edited
    # stays paused — say so rather than implying it's live.
    def schedule_saved_text(user, schedule)
      return schedule_created_text(user, schedule) if schedule.enabled?

      "✅ Updated — #{schedule_label(schedule)} (still paused). Resume it any time in /schedules."
    end

    def sched_builder_key(update)
      "sched_builder:#{update.chat_id}"
    end

    def read_sched_builder(update)
      Rails.cache.read(sched_builder_key(update)) || {}
    end

    def write_sched_builder(update, data)
      Rails.cache.write(sched_builder_key(update), data, expires_in: SCHED_BUILDER_TTL)
    end

    def clear_sched_builder(update)
      Rails.cache.delete(sched_builder_key(update))
    end

    # Sends a fresh message or edits the current one, used across the button-first
    # builder/manager so a tap updates in place while a command starts fresh.
    def send_or_edit(update, text, reply_markup, edit:)
      if edit
        client.edit_message_text(chat_id: update.chat_id, message_id: update.message_id, text: text, reply_markup: reply_markup)
      else
        client.send_message(chat_id: update.chat_id, text: text, reply_markup: reply_markup)
      end
    end

    def local_date_for(user)
      return Date.current unless user.timezone.present?
      Time.current.in_time_zone(user.timezone).to_date
    end
  end
end
