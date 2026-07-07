# QuoterBack Bot — Code Review Findings (2026-07-07)

> **Audience:** the Opus fixer agent. Each finding states the problem, where it lives, and the
> fix to apply — follow the prescribed approach, don't redesign. The reference spec is
> `docs/implementation_plan.md` (cited as "plan §n"). Current state: 188 rspec examples, all
> green — so every bug below is also an **uncovered test case**; add a spec with each fix.
>
> Severity: **C** = correctness bug users will hit, **M** = medium bug / rough edge,
> **G** = feature gap vs the plan (listed so nobody mistakes "not built yet" for "works").

---

## C. Critical correctness bugs

### C1. `/list` inline keyboard puts up to 10 buttons in one row — Telegram caps rows at 8 ✅ IMPLEMENTED
`app/services/bot/dispatcher.rb` `render_list` (~line 455): `number_buttons` is built as a
**single row** of one button per quote on the page, and `PAGE_SIZE = 10`. Telegram rejects
inline-keyboard rows with more than 8 buttons (`Bad Request`), so any list page with 9–10 quotes
fails to send — and because `dispatch` swallows `StandardError` (see C7), the user gets **total
silence** from `/list` once they have 9+ quotes. This is the single most user-visible bug.

**Fix:** `number_buttons.each_slice(5).to_a` and splat those rows into `keyboard` (two rows of
≤5). Keep `PAGE_SIZE` at 10. Add a dispatcher spec asserting that with 10 quotes no keyboard row
exceeds 8 buttons.

### C2. Markdown asterisks sent without `parse_mode` — literal `*` shown to users ✅ IMPLEMENTED
No call in the codebase passes `parse_mode` (verified by grep), yet many messages contain
Markdown chrome: `*QuoterBack*` (handle_start), `*Settings*`, `*QuoterBack Help*`,
`*Common timezones:*`, `*#{tz.name}*` (apply_timezone ×2), `*##{tag.name}*`
(handle_awaiting_tag_name), `*HH:MM*` (handle_schedule_command). All of these render with raw
asterisks in Telegram.

**Fix — decide once, per plan §6.5:** stay **plain text** (no `parse_mode`) and **remove the
asterisks** from all bot copy. Do NOT globally enable Markdown/MarkdownV2: several of these
messages interpolate user content (tag names are safe post-normalization, but quote content and
timezone input echoes are not), and MarkdownV2 escaping is a bug farm. Plain text is the plan's
recommended choice. Grep for `\*` in `app/services/bot/dispatcher.rb` and strip.

### C3. Quote/tag validation failures are silent dead-ends and can wedge the state machine ✅ IMPLEMENTED
`Quote` validates `content` length 3..1000; `Tag` validates name max 30. Several creation paths
call `create!`/`find_or_create_by!` with no rescue, so `ActiveRecord::RecordInvalid` bubbles to
`dispatch`'s blanket rescue → logged, **no reply to the user**:

- `handle_add` (`/add hi`, or `/add <1000+ chars>` — Telegram allows 4096) → silence.
- `handle_awaiting_quote_text` → silence **and the user stays stuck in `awaiting_quote_text`**
  (the `create!` raises before `state: nil` is written), so every subsequent message also fails
  silently until they discover `/cancel`.
- `handle_awaiting_tag_name` → a 31+ char tag passes the local `/\A[a-z0-9_]+\z/` check but
  fails the model's max-30 validation → silence, stuck in `awaiting_tag_name`.
- `handle_confirm_on_text` happily offers to save a 2-char or 4000-char message; only the
  confirm-yes path rescues `RecordInvalid` (and replies with a raw validation message).

**Fix (choke point — aligns with plan §9.7/N9):** introduce one creation entry point, e.g.
`QuoteCreator.call(user:, content:)` returning a success/failure result with a **human**
message ("Quotes need to be 3–1000 characters"), and route `/add`, `awaiting_quote_text`, and
confirm-yes through it. On failure: reply with the message; in `awaiting_quote_text` keep the
state and re-prompt (that's the natural "try again" loop). For tags: enforce max 30 in
`handle_awaiting_tag_name`'s validation step (extend the regex check to `length <= 30`) and
reply with the existing "try again" pattern. This choke point is also where the free-tier limit
stub (G8) slots in later — build it with that in mind.

### C4. `QuoteScheduler.schedule_for`'s transaction does not actually close the N5 race in production ✅ IMPLEMENTED
`app/services/quote_scheduler.rb:13`: the enqueue + `schedule.update!(pending_job_id:)` are
wrapped in `ActiveRecord::Base.transaction`, per plan §7.1/N5. But in **production** Solid Queue
lives in a separate `queue` SQLite database (`config/database.yml`), so the job INSERT commits on
a different connection and is **not** covered by the primary-DB transaction. A near-now job
(same-minute reschedule) can be claimed and run the stale-job guard before `pending_job_id`
commits → guard sees a mismatch → aborts → that day's delivery is silently skipped (the 2 am
safety net only reschedules *future* runs). Dev/test share one DB, which is why specs pass.

**Fix:** persist the id **before** the job can run: instantiate first, then persist, then enqueue —
```ruby
job = DeliverQuoteJob.new(schedule.id, run_at.to_date.iso8601)  # job_id is assigned at .new
schedule.update!(pending_job_id: job.job_id)
job.set(wait_until: run_at).enqueue                              # or job.scheduled_at = ...; job.enqueue
```
Drop the transaction (it's decorative across DBs). If enqueue raises, clear `pending_job_id` in a
rescue. Update `quote_scheduler_spec` to assert the id is readable before the job is enqueued.

### C5. `q:rand:<schedule_id>` ignores the schedule scope ✅ IMPLEMENTED
`DeliverQuoteJob` sends the delivery card with `🎲 Another → q:rand:#{schedule.id}` and the plan
(§7.2/UX15) says "Another" must draw from the **same schedule's scope** (tag-scoped schedules).
`handle_quote_random_callback` (`dispatcher.rb:332`) discards the captured id and always samples
the whole collection. Today all schedules are `tag_id: nil` so nobody notices, but the moment a
tag-scoped schedule exists (schema already supports it) this returns out-of-scope quotes.

**Fix:** pass the captured id through; if `> 0`, look up `user.delivery_schedules.find_by(id:)`
and, when it has a `tag_id`, call `Quote.random_for(user, tag: schedule.tag)`. `0` keeps the
whole-collection behaviour. Extract the shared "select quote for scope" logic so the job and the
dispatcher use one implementation (the job additionally applies favourite weighting — move
`weighted_sample` into `Quote.random_for` or a shared module rather than duplicating).

### C6. `edit_message_text` "message is not modified" is not swallowed (plan §15 requires it) ✅ IMPLEMENTED
Nothing handles Telegram's `Bad Request: message is not modified`. Two real triggers:
- `🎲 Another` when the user has 1 quote (or the LRU pool re-picks the same quote): the edit has
  identical text → 400 → `TelegramClient::Error` → aborts `handle_quote_random_callback`
  **before** the `quote_deliveries.create!` / counter bump, and is then eaten by the global rescue.
- Tapping ⬅️/➡️ pagination fast, or re-tapping the current page.

**Fix:** in `TelegramClient#method_missing`'s rescue, detect
`e.message.include?("message is not modified")` and **return nil silently** (only for that
error). That fixes every call site at once and matches the plan's "handle silently" instruction.

### C7. `Dispatcher#dispatch`'s blanket rescue hides everything and never reports to Rollbar
`dispatcher.rb:21`: `rescue StandardError` → `Rails.logger.error` only. Consequences: (a) every
bug above is invisible to the user *and* to Rollbar (the initializer exists but only captures
unhandled exceptions — these are handled); (b) a failure inside a **callback** handler leaves the
Telegram button spinner running forever because `answer_callback_query` is never sent.

**Fix:** in the rescue: `Rollbar.error(e, chat_id: update&.chat_id)`; if
`update&.callback_query_id` is present, best-effort
`client.answer_callback_query(callback_query_id:, text: "Something went wrong — try again")`
(wrapped in its own `rescue nil`); optionally send a short "Something went wrong" message for
text-command failures. Also add `Rollbar.error` to `Bot::Poller`'s rescue and to the
`rescue => e` blocks in `DeliverQuoteJob`/`ScheduleQuotesJob`.

---

## M. Medium bugs & uncovered edge cases

### M1. `/command@BotName` form is not recognized
In groups (and sometimes via autocomplete in DMs) Telegram sends `/quote@QuoterBackBot`. The
`case command.downcase` matches nothing → falls through to **confirm-on-text**, so the bot asks
"Add this as a quote? _/quote@QuoterBackBot_". **Fix:** after splitting, strip a trailing
`@\S+` from `command` (`command = command.sub(/@[\w_]+\z/, "")`) before the `case`.

### M2. Half-hour/quarter-hour and edge UTC offsets unparseable
`Bot::TimezoneParser` regex `\A(?:UTC)?([+-]\d{1,2})(?::00)?\z` rejects `+5:30` (India — huge
Telegram population), `+9:30`, `+5:45`, and the map lacks `+13`/`+14`. **Fix:** extend the regex
to capture minutes `(?::(\d{2}))?`; add `OFFSET_TO_ZONE` entries: `5.5 => "Chennai"`,
`5.75 => "Kathmandu"`, `6.5 => "Rangoon"`, `9.5 => "Darwin"`, `12.75/13 => "Nuku'alofa"`
(pick any valid Rails zone per offset; verify each with `ActiveSupport::TimeZone[name]`), keying
the hash by float hours. Also worth a tiny alias map for top cities Rails doesn't name
(`"new york" => "Eastern Time (US & Canada)"`, `"los angeles" => "Pacific Time (US & Canada)"`,
`"kyiv"/"kiev"`, `"berlin"`, `"toronto"`) — cheap, high-value.

### M3. Invalid-timezone reply arrives in the wrong order
`apply_timezone` (dispatcher.rb:630) sends the **picker first, then** the "Couldn't recognize…"
explanation, so the user sees the error *below* the picker. Swap the two calls (error message
first, picker second).

### M4. `q:show` "Back to list" loses pagination and tag context
`handle_quote_show` hardcodes `list:pg:1`. A user on page 4 of a tag-filtered list who opens a
detail card returns to page 1, unfiltered. **Fix:** thread `page` and `tag_id` through the
`q:show` callback data (e.g. `q:show:<id>:<page>:<tag_id?>` — still well under 64 bytes) and
build the back button from them; number buttons in `render_list` already know both.

### M5. `q:show` on a deleted quote gives no feedback
`handle_quote_show` does `return unless quote` after the spinner was cleared — the tap appears to
do nothing. **Fix:** `edit_message_text` to the standard "🤷 That quote's no longer here." card
with a `[📋 See your list]` button (pattern already exists in `handle_delete_confirm_callback`).

### M6. Tag picker spams a new message on every toggle
`handle_tag_add`/`handle_tag_remove` re-render by calling `handle_tag_picker`, which always
`send_message`s — each tag toggle stacks another picker in the chat. Plan §8.5 mandates
edit-in-place. **Fix:** give `handle_tag_picker` an `edit:` flag (like `render_list`); the
initial `q:tag` entry may send a new message, but re-renders after add/remove must
`edit_message_text` on `update.message_id`. (Note: after C6's fix, identical re-renders are safe.)

### M7. `qc:no` (and picker/cache flows) skip the `from_id` ownership check
`handle_quote_confirm_no` deletes the pending entry with no ownership check — in a group, anyone
can dismiss another member's pending quote. **Fix:** same `entry[:from_id] == update.from_id`
guard as the yes-path (read entry before deleting; if entry is nil just answer the callback).

### M8. `Tag#normalize_name` disagrees with the dispatcher's normalization
Model: strips **one** leading `#` (`/\A#/`), downcases, strips — but does **not** collapse
internal whitespace to `_`. Dispatcher (3 call sites): `/\A#+/` + `gsub(/\s+/, "_")`. Any future
path creating tags through the model alone (import, `/tag` fallback) can produce names with
spaces that `/quote #tag` can then never match. **Fix (plan N13 — one place):** move the full
normalization (`sub(/\A#+/, "")`, `downcase`, `strip`, `gsub(/\s+/, "_")`) into the model's
`normalize_name`, add a format validation `/\A[a-z0-9_]+\z/`, and have the dispatcher call a
single `Tag.normalize(raw)` helper for lookups instead of three inline copies
(`handle_quote`, `resolve_list_tag`, `handle_awaiting_tag_name`).

### M9. `/start` payload is captured then ignored
`handle_start(update, user, rest.presence)` accepts the deep-link payload and does nothing with
it. Plan §18.2.5: a `q_<public_id>` payload must answer "Shared quotes are coming soon!" (any
other unknown payload: ignore). One `if payload&.start_with?("q_")` branch.

### M10. "ready" state and helpers are dead; `/start` semantics fuzzy
`STATES` includes `ready` but nothing ever sets it; `User#configured?`/`#awaiting_state?` are
unused; `handle_start` guards `unless user.state == "ready"` — a condition that can never be
true. Per plan §11 the terminal onboarding confirmation (first successful `apply_timezone`)
should set `state: "ready"`, not `nil`. **Fix:** set `"ready"` there, and treat
`ready`/`new`/`nil` identically in routing (they already are — only `awaiting_*` states branch).
Low risk, restores the invariant the code pretends to have.

### M11. `/cancel` is overloaded, contradicting plan UX23
With no active state, `/cancel` disables **all** schedules. Plan UX23 explicitly reserves
`/cancel` for aborting the current flow; schedule removal belongs to the `/schedules` manager
(`sched:del`). Since `/schedules` doesn't exist yet (G1), this is currently the *only* way to
stop delivery — **keep the behaviour for now**, but when G1 lands, `/cancel` with no state should
become "Nothing to cancel. Manage deliveries in /schedules." Leave a TODO referencing UX23.

### M12. A quote containing "ping me in" can never be saved
The easter-egg branch `text.match?(/ping me in/i)` runs before confirm-on-text, so any plain
message containing that substring triggers PingJob instead of the save prompt. Tighten to an
anchored match (`/\Aping me in\s+\d+/i`) or drop the easter egg.

### M13. Non-text messages are silently ignored
Photos (even with captions), documents, stickers, voice → `UpdateParser` yields
`text: nil, callback_data: nil` → `dispatch` does nothing. Until the image/import features (G4,
G5) exist, reply once with "I can only save text quotes right now — send me the text!" when a
`message` update has no text. Requires `UpdateParser` to expose a flag (e.g. parse `photo`/
`document` presence — groundwork G4 needs anyway).

### M14. Missing production boot check for `TELEGRAM_WEBHOOK_SECRET` (plan §13, L1/N2)
`config/initializers/` has no `webhook_secret_check.rb` — a prod deploy with the secret unset
runs with webhook auth silently disabled. Implement exactly per plan §13: raise in production
boot when blank, guarded by `next if ENV["SECRET_KEY_BASE_DUMMY"].present?` so image builds pass.

### M15. Missing test coverage (all green ≠ all covered)
- **No request spec for `TelegramWebhooksController`** — plan §15 requires: valid/invalid/blank
  secret; and "returns 200 even when the dispatcher raises". (The dispatcher rescues internally,
  but a spec must pin that a raising handler still yields `head :ok`, and that a raise in
  `UpdateParser` itself doesn't 500.)
- **No `TelegramClient` spec** — pin the `reply_markup` JSON-encoding behaviour, the 403 →
  `Forbidden` mapping, and (after C6) the "message is not modified" swallow.
- Add specs alongside every C/M fix above; C1 (row width), C3 (stuck states), C4 (id persisted
  pre-enqueue) are the priority ones.

### M16. Dev cache semantics differ from the plan's assumption
`development.rb` uses `:memory_store`; plan §6.2 asserts pending-confirm entries "survive app
restarts" (true only for prod solid_cache). In dev the poller process owns the cache, so a poller
restart invalidates pending confirmations/tz pickers → users see "expired". Acceptable — but
don't "fix" expiry messaging to mention restarts, and be aware webhook-mode testing in dev would
put writer (web) and reader (web) in the same process, which still works. No code change; noted
so Opus doesn't chase it as a bug.

---

## G. Feature gaps vs `docs/implementation_plan.md` (not yet built — confirm scope before building)

These are plan-mandated features with **zero implementation**. They look like phase-5+ work; the
fixer should confirm with the author which are in scope now. Ordered by user impact:

1. **`/schedules` manager + interactive `/schedule` builder** (plan §9.3, UX13/14): no `sched:*`
   callbacks exist anywhere. No way to pause/resume/edit/delete a schedule except the overloaded
   `/cancel` (M11). Multi-schedule + per-tag schedules are fully supported by the engine/schema
   but unreachable from the UI (`/schedule` always reuses `first_or_initialize`, `tag_id` always
   nil).
2. **`/settings` buttons are all dead**: every `set:*` callback answers "🚧 Coming soon!". Cheap
   partial win now: wire `set:tz` → `show_timezone_picker` (handler exists) even if the rest wait.
3. **`q:bytag` is a dead path**: the callback handler exists (dispatcher.rb:125) but **nothing
   ever renders a `q:bytag` button** (plan §9.1: bare `/quote` should offer a top-tags row).
   Either render the row or note the handler is forward-wiring.
4. **Images** (plan §6.6): no photo/document extraction in `UpdateParser`, no confirm-on-photo,
   no `AttachQuoteImageJob`, no `send_photo` delivery/caption/fallback. Schema (`photo_file_id`,
   Active Storage tables) is ready. Also `production.rb` has `active_storage.service = :local`
   (plan says `:amazon`) and `.env.example` lacks the AWS vars — both part of this work item.
5. **`/import`** (plan §6.4): `awaiting_import_file` state exists in `STATES`, nothing handles it.
6. **Tag management**: no `/tags` command; no tag-delete flow (`tag:dely`/`tag:deln` with the
   blast-radius confirmation naming affected schedules, plan §8.5.5).
7. **`/dnd` + snooze** (plan §9.5): `dnd_weekdays` column exists, wholly unused; delivery card
   lacks `😴 Snooze today`; delivery card buttons diverge from UX15 (`Delete/Another` instead of
   `Fav/Another/Snooze`) — reconcile when building this.
8. **Free-tier limit stub** (plan §9.7): `FREE_QUOTE_LIMIT`/`premium?` choke point — build it on
   the `QuoteCreator` introduced by C3.
9. **`/stats`** (plan §9.6): streak data is being collected (`streak_count`/`streak_last_date`)
   but is never shown to anyone.
10. **Typed-id fallback commands** `/tag`, `/untag`, `/fav`, `/unfav` (plan §8.5.3) — plan calls
    them optional power-user fallbacks; lowest priority.
11. **Minor plan deltas:** `bot:quote_now[chat_id]` rake task missing (only `ping_now` exists);
    `/list` empty state lacks the `[📥 Import] [🎲 Example]` buttons (UX12); expired-confirm lacks
    "✍️ Add anyway" (§8.5.6); first-capture success card mentions scheduling but offers no
    `⏰ Set daily time` button (UX5 — blocked on G1's `sched:new`); no `.kamal/hooks/pre-app-boot`
    (harmless: `bin/docker-entrypoint` runs `db:prepare`).

---

## Architecture notes for the fixer (decisions already made — follow them)

- **Layering stays as-is:** controller/poller → `UpdateParser` → `Dispatcher` → services/jobs.
  New logic goes in service objects (`QuoteCreator`, extend `QuoteScheduler`), not the dispatcher.
  The dispatcher is 895 lines and growing — when touching it, prefer extracting handlers over
  adding inline branches, but do **not** attempt a wholesale refactor in this pass.
- **Plain text everywhere** (C2): no `parse_mode`. This is a product decision from plan §6.5.
- **One quote-creation choke point** (C3 → G8): `QuoteCreator.call(user:, content:)` is the only
  place quotes are born. All current and future capture paths (add, state, confirm-yes, import,
  photo) must route through it.
- **One tag-normalization home** (M8): the `Tag` model. Dispatcher only calls it.
- **Scheduling invariants** (C4): `pending_job_id` must be committed **before** the job is
  enqueued (instantiate → persist id → enqueue). The stale-job guard in `DeliverQuoteJob` stays
  as the backstop; do not weaken it.
- **Error policy** (C6/C7): `TelegramClient` swallows only "message is not modified"; every other
  API error stays typed (`Forbidden`/`Error`). The dispatcher's blanket rescue reports to Rollbar
  and always answers pending callback queries.
- **Ownership checks:** all quote/tag/schedule lookups stay scoped (`user.quotes.find_by(id:)`);
  cache-backed confirmations verify `from_id` on **both** yes and no paths (M7).
- **Every fix ships with a spec** (M15); no test may hit the network (webmock is configured).
