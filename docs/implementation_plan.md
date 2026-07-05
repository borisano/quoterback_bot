# QuoterBack Bot — Implementation Plan

> **Audience:** implementation agents (some may be simpler models). This plan is prescriptive.
> Follow it top-to-bottom. Where an edge case is flagged with ⚠️, do **not** skip it — those
> are the exact places naive implementations break.
>
> **Reference implementation:** `~/projects/eye_on_sky_bot` (same author, same tech stack,
> production-proven). Mirror its architecture and conventions closely. Where this plan says
> "as in eye_on_sky", open that file and copy the *pattern* (not necessarily the code verbatim).
>
> **Do NOT copy from** `~/projects/quoterback_bot_old` — it is a discarded prototype. We reuse
> only its *feature list*, not its implementation (it used an inefficient per-minute timezone
> scan, had no delete, no pagination, and a fat controller with all logic inline).

---

## 1. Product summary

A Telegram bot where each user builds their **own** private quote collection and gets quotes
back on demand or on a daily schedule (timezone-aware). See `README.md` and
`docs/product_research.md` for the product vision. This document is the build spec.

**Scope of this plan:** MVP **and** V2 features, in detail. V3/AI features and payment
integration are explicitly out of scope (free-tier limits are documented as a stub only).

---

## 2. Tech stack (fixed — do not deviate)

| Concern | Choice | Notes |
|---|---|---|
| Framework | **Ruby on Rails 8.1.x** | Match `eye_on_sky_bot`'s `.ruby-version` (3.4.3) |
| Database | **SQLite** (multi-db) | `primary`, `cache`, `queue`, `cable` DBs, exactly as eye_on_sky's `config/database.yml` |
| Background jobs | **Solid Queue** | Runs in-Puma via `SOLID_QUEUE_IN_PUMA=true` on the single server |
| Cache / state | **Solid Cache** | Used for the confirm-on-text pending-quote store |
| Cable | **Solid Cable** | Default; not heavily used |
| Telegram | **telegram-bot-ruby** | Webhook in prod, long-polling in dev |
| HTTP client | **faraday** | Only if needed (e.g. V3); MVP has no external APIs |
| Assets | **propshaft + importmap + turbo + stimulus** | Only for the admin dashboard UI |
| Errors | **rollbar** | Same initializer pattern as eye_on_sky |
| Images | **Active Storage + `image_processing` (libvips) + `aws-sdk-s3`** | Quote image attachments. **Local disk service in dev/test, S3 in production.** `libvips` is already in the reference Dockerfile. |
| Deploy | **Kamal 2** (kamal-proxy) | Same server as eye_on_sky, host-routed by subdomain |
| Tests | **rspec-rails + factory_bot + webmock + vcr + shoulda-matchers** | Mirror eye_on_sky's `spec/` layout |
| Lint / security | **rubocop-rails-omakase, brakeman, bundler-audit** | Same as eye_on_sky |

**Bootstrap command:**
```bash
rails new quoterback_bot --database=sqlite3 --skip-jbuilder
```
Then align the `Gemfile` with `~/projects/eye_on_sky_bot/Gemfile` (add telegram-bot-ruby,
rollbar, dotenv-rails, rspec-rails, factory_bot_rails, webmock, vcr, shoulda-matchers,
bundler-audit; keep solid_queue/solid_cache/solid_cable, kamal, thruster, bootsnap).
⚠️ The current repo already contains `README.md` and `docs/` — generate the Rails app in place
and **do not overwrite** those files.

---

## 3. Architecture overview

Follow eye_on_sky's **service-object** layering. Keep the controller thin.

```
Telegram ──(webhook, prod)──▶ TelegramWebhooksController#create
         ──(long-poll, dev)─▶ Bot::Poller
                                      │
                                      ▼
                            Bot::UpdateParser.parse  ──▶ ParsedUpdate (Data struct)
                                      │
                                      ▼
                            Bot::Dispatcher#dispatch   ← routes commands / callbacks / state
                                      │
                    ┌─────────────────┼───────────────────────┐
                    ▼                 ▼                         ▼
        Quote/Tag/Schedule      QuoteScheduler         TelegramClient (Bot API facade)
        models (per-user)       (per-SCHEDULE jobs,
                                 keyed by pending_job_id)
                                      │
                                      ▼
                DeliverQuoteJob(schedule_id) — self-reschedules, sends from the schedule's
                scope (whole collection or a tag), text or photo
                                      +
                ScheduleQuotesJob — daily 2am safety net over enabled schedules
                                      +
                AttachQuoteImageJob — downloads Telegram photo → Active Storage (S3 in prod)
```

### Files to create (mirror eye_on_sky names)
- `app/controllers/telegram_webhooks_controller.rb`
- `app/services/bot/update_parser.rb` — **copy structure from eye_on_sky nearly verbatim**; extend to extract `photo` (array) and `document`. Already handles dev typed objects, webhook hashes, and `ActionController::Parameters`.
- `app/services/bot/poller.rb` — copy nearly verbatim.
- `app/services/bot/dispatcher.rb` — bot-specific; the bulk of the work.
- `app/services/telegram_client.rb` — **copy verbatim** (facade with `Forbidden`/`Error` typed exceptions + `reply_markup` JSON serialization). ⚠️ Do not hand-roll Bot API calls; the `reply_markup` hash-serialization gotcha below is why this facade exists.
- `app/services/bot/quote_presenter.rb` — formats a quote for display / photo caption (see §6.5).
- `app/services/quote_scheduler.rb` — schedule-centric scheduler (see §7.1).
- `app/jobs/deliver_quote_job.rb`, `app/jobs/schedule_quotes_job.rb`, `app/jobs/attach_quote_image_job.rb`.
- `app/models/user.rb`, `app/models/quote.rb`, `app/models/tag.rb`, `app/models/tagging.rb`, `app/models/delivery_schedule.rb`, `app/models/quote_delivery.rb`.
- `lib/tasks/bot.rake` — `bot:poll`, `bot:set_webhook`, `bot:delete_webhook`, `bot:set_commands` (registers the native Telegram command menu via `setMyCommands` — issue UX7/§8.5.1), `bot:quote_now[chat_id]`.
- Admin: `app/controllers/admin/dashboard_controller.rb`, `app/queries/admin/stats_query.rb`, view.

---

## 4. Data model

### `users`
One row per Telegram chat. This is the settings + onboarding-state holder.

| Column | Type | Notes |
|---|---|---|
| `telegram_chat_id` | bigint | **unique, not null**. ⚠️ Telegram IDs exceed 32-bit — declare `t.bigint`. |
| `first_name` | string | from update, best-effort |
| `telegram_language_code` | string | for future i18n |
| `locale` | string | nullable; default `en` for now |
| `timezone` | string | IANA name, e.g. `Europe/London`; nullable until set |
| `state` | string | onboarding/conversation state machine (see §11) |
| `active` | boolean | default true; set false on Telegram 403 (blocked) |
| `streak_count` | integer | default 0 (V2 §9.4) |
| `streak_last_date` | date | nullable; last local date a delivery counted (V2 §9.4) |
| `dnd_weekdays` | string/json | nullable; set of 0–6 weekdays with no delivery (V2 §9.5) |
| `last_interaction_at` | datetime | |
| timestamps | | |

⚠️ **Schedule columns are intentionally NOT on `users`.** Unlike the old prototype, delivery
schedules live in their own `delivery_schedules` table **from day one** (MVP creates exactly one
row per user). This avoids the painful single-schedule→multi-schedule migration the critic
flagged (old §9.3 / issue H4) and lets the delivery job be keyed by `schedule_id` uniformly.

⚠️ **Do not** store the "pending confirm-on-text quote", "pending photo", or "import in progress"
blobs as user columns — use Solid Cache with TTL (see §6.2 / §6.6). Durable state (onboarding
`state`, `timezone`) goes on the row; ephemeral 10-minute stuff goes in cache.

### `quotes`
| Column | Type | Notes |
|---|---|---|
| `user_id` | references, not null, indexed | FK to users; **scope every query by this** |
| `content` | text, not null | length 3..1000 (validate) |
| `author` | string | optional, max 100 |
| `source` | string | optional, max 200 (book/film/etc.) |
| `photo_file_id` | string | nullable; Telegram `file_id` of the largest photo size (see §6.6) |
| `favourited` | boolean | default false (V2) |
| `times_delivered` | integer | default 0 (V2 weighting + stats) |
| `last_delivered_at` | datetime | nullable (V2) |
| timestamps | | |

Also `has_one_attached :image` (Active Storage) for the durable copy of the photo (see §6.6).
Indexes: `index_quotes_on_user_id`, composite `(user_id, created_at)` for paginated `/list`,
and `(user_id, id)` (natural — covers scoped `find_by(id:)` for `/delete`).

⚠️ **Scoping is a security boundary.** Every read/write must go through `user.quotes` or
`Quote.where(user_id: ...)`. A quote must never be visible or deletable by another user. Applies
especially to `/delete [id]`, tag/schedule operations, and callback data (see §8).

⚠️ **Forward-compat (see §18):** a future public-sharing/discovery feature will add
`visibility` / `public_id` / `forked_from_id` / vote-counter columns to `quotes` — purely
additive, nothing to build now. The one thing to honor from day one: **never build a
user-shareable link or public reference on the raw integer PK** (use the future non-enumerable
`public_id`), and keep the ownership rule above for all *writes* and for reading *private*
quotes (public discovery will use a separate, explicit public read scope, not a hole in this one).
⚠️ **Deletion semantics (issue N14):** MVP `/delete` hard-destroys. §18 later needs
soft-delete/tombstones for public quotes that have votes/forks. This is not a blocker, but be
aware `/delete` and the `dependent:` cascades will be reworked then; if cheap, introduce a
`deleted_at` column + `default_scope`/`kept` scope early to avoid a later data migration.

`user has_many :quotes, dependent: :destroy` (and same for tags, schedules). ⚠️ Declare
`dependent:` on every association so a (rare, admin-initiated) user deletion doesn't orphan rows
or hit FK violations (issue L5).

### `tags` + `taggings` (core for the tag/per-tag-schedule feature)
```
tags:      user_id (FK, not null), name (string, not null), timestamps
           unique index (user_id, name)          # per-user namespace
taggings:  quote_id (FK, not null), tag_id (FK, not null), timestamps
           unique index (quote_id, tag_id)        # many-to-many, idempotent
```
- A quote `has_many :tags, through: :taggings`; a tag `has_many :quotes, through: :taggings`.
- Normalize `name`: strip leading `#`, `downcase`, trim, max ~30 chars, allow `[a-z0-9_]`.
- ⚠️ Tags are **per-user** — one user's `motivation` is unrelated to another's. Never global.
- `tag has_many :taggings, dependent: :destroy`; `tag has_many :delivery_schedules,
  dependent: :destroy` (deleting a tag removes its tag-scoped schedules — see §7).

### `delivery_schedules` (the scheduling unit — MVP and V2)
```
delivery_schedules:
  user_id (FK, not null, indexed)
  tag_id  (FK, NULLABLE, indexed)      # NULL = whole collection; set = only that tag's quotes
  hour    (integer 0–23, not null)
  minute  (integer 0–59, not null, default 0)
  enabled (boolean, not null, default true)
  label   (string, nullable)           # optional user-facing name
  pending_job_id (string, nullable, indexed)   # ActiveJob id of the currently-enqueued
                                               # DeliverQuoteJob for THIS schedule (see §7)
  timestamps
```
- MVP: `/schedule HH:MM` creates/updates a single row with `tag_id: nil`.
- V2 (tag feature): a user may have **many** schedules, each optionally tag-scoped.
- ⚠️ `pending_job_id` is the key design that fixes the critic's C1/C2 (see §7.1). It makes
  "find/cancel this schedule's pending job" an **indexed lookup**, not an O(N) scan of
  `SolidQueue::Job` arguments.
- ⚠️ Consider a partial-uniqueness rule to avoid accidental duplicate schedules for the same
  `(user_id, tag_id, hour, minute)` — validate in the model (SQLite partial indexes are fiddly).

### `quote_deliveries` (audit log — backs admin stats & streaks)
```
quote_deliveries:
  user_id (FK, not null, indexed)
  quote_id (FK, nullable, on_delete: :nullify)   # keep the audit row if the quote is deleted
  delivery_schedule_id (FK, nullable, on_delete: :nullify)  # which schedule fired it (nil = on-demand)
  local_date (date, not null)          # the delivery date in the USER'S timezone
  context (string)                     # "scheduled" | "on_demand"
  delivered_at (datetime, not null)
  unique index (user_id, delivery_schedule_id, local_date)   # ⚠️ see below (issue N1)
```
- ⚠️ **Unique `(user_id, delivery_schedule_id, local_date)`** (issue N1 — NOT `(user_id,
  local_date)`). A user with several tag-schedules legitimately receives several quotes on the
  same day; a bare `(user_id, local_date)` unique index would drop every row after the first,
  making the `delivery_schedule_id` audit useless and undercounting §10's "deliveries today". The
  per-schedule uniqueness still dedupes the one case it must: a **single schedule** re-firing the
  same day (user changed its time). On that collision the second insert raises `RecordNotUnique`
  — **rescue it and move on** (the message was still sent; this is an audit trail, not a delivery
  guard).
  - ⚠️ For **on-demand** deliveries `delivery_schedule_id` is nil. SQLite treats NULLs as distinct
    in unique indexes, so multiple on-demand rows per day coexist (they don't dedupe) — that's
    fine; on-demand deliveries are not deduped (see N10 / §6.1).
- ⚠️ **Streaks (§9.4) count `DISTINCT local_date`**, never row count — correct regardless of how
  many schedules delivered that day.

---

## 5. Telegram integration

### 5.1 Two runtimes, one code path
- **Development:** `bin/rails bot:poll` → `Bot::Poller` long-polls and feeds `Bot::Dispatcher`.
- **Production:** Telegram calls `POST /telegram/webhook` → controller → `Bot::Dispatcher`.
- Both normalize through `Bot::UpdateParser` so the dispatcher never sees raw Telegram shapes.

⚠️ **Never run polling and webhook simultaneously for the same bot token** — Telegram rejects
`getUpdates` while a webhook is set. Dev uses a **separate dev bot token** (`@YourBot_dev`);
prod uses the real token via Kamal secrets. Document this in `.env.example`.

### 5.2 Webhook security
Copy eye_on_sky's `verify_secret_token` before_action verbatim:
- Compare `X-Telegram-Bot-Api-Secret-Token` header to `ENV["TELEGRAM_WEBHOOK_SECRET"]` using
  `ActiveSupport::SecurityUtils.secure_compare`.
- If the env var is blank, skip verification (dev/test convenience). In prod it MUST be set.
- Register the webhook with the same secret via `rails bot:set_webhook` (reads `WEBHOOK_URL` +
  `TELEGRAM_WEBHOOK_SECRET`).

⚠️ The controller must **always `head :ok`** quickly, even on internal errors. If you return 5xx,
Telegram retries the same update repeatedly (→ duplicate quotes/messages). Wrap dispatch so
exceptions are logged (Rollbar) but the HTTP response is still 200. eye_on_sky's dispatcher
already rescues `StandardError` internally — keep that.

### 5.3 TelegramClient facade — the `reply_markup` gotcha ⚠️
telegram-bot-ruby only auto-serializes `reply_markup` for its own typed keyboard objects.
If you pass a **plain Ruby hash** for inline/reply keyboards, Faraday form-encodes it and
**Telegram silently drops the keyboard** (no error, button just doesn't appear). The
`TelegramClient` facade JSON-encodes `reply_markup` hashes for you. Always send keyboards
through the facade; never call the raw API directly.

### 5.4 Error handling
- `TelegramClient::Forbidden` (403) = user blocked the bot → set `user.active = false`, stop
  scheduling for them. Do **not** retry 403.
- `TelegramClient::Error` (other 4xx/5xx/timeout) = transient → in jobs, `retry_on` with backoff
  (see §7.3).

---

## 6. Quote features (MVP + image attachments)

### 6.1 Commands
Implement in `Bot::Dispatcher#handle_text`, routing on the first whitespace-delimited token
(as eye_on_sky does: `text.split(/\s+/, 2)`). Support aliases.

⚠️ **Button-first (see §8.5):** commands are a fallback/power path. The primary interface is the
native command menu (`setMyCommands`, UX7/§8.5.1) + inline buttons. The `[id]`/`<id>` command forms
below all still parse, but a normal user never types an id — they tap the per-quote action row
(§8.5.2). Only the canonical, zero-argument commands appear in the menu (UX24).

| Command | Aliases | Behaviour |
|---|---|---|
| `/start` | | Onboarding: greet, then a **tap-only** button path (set timezone → add first quote), no typing required to progress (UX1, §11). Idempotent — re-running never duplicates the user (`find_or_create_from_update!`). |
| `/help` | | Sectioned command list (*Capture · Browse · Deliver · Organise · Account*) ending with launcher buttons `[🎲 Random] [📋 Browse] [⏰ Schedules]` (UX8), not a flat dump. |
| `/add [text]` | | If text present, add directly. If bare `/add`, set state `awaiting_quote_text` and prompt. |
| `/quote [#tag]` | `/random` | Random quote right now. With a `#tag` (or **exact** tag word, issue N11) → random from that tag; bare form may render an inline row of top tags (`q:bytag:<tag_id>`, §9.1). Result carries the per-quote action row (§8.5.2). |
| `/list [#tag]` | `/quotes` | **Paginated** button-driven browse with per-item detail tap targets and tag-filter buttons (see §6.3 / §8.5.4). |
| `/delete [id]` | | Delete quote by id (fallback for the `🗑` button, `q:del:<id>`; always confirmed — §8.5.5). See ⚠️ below. |
| `/settings` | | **Button-driven control panel** (UX21) — status line + buttons to Timezone / Schedules / Tags / DND / Stats / Import. NOT a text dump. See §6.7. |
| `/schedule [HH:MM]` | | Create/update a delivery schedule. Bare form → interactive builder: pick tag-or-"Any" → **inline hour+minute grid** (typing HH:MM is a fallback, UX13). See §7 / §9.3. |
| `/schedules` | | List schedules with per-row `✏️ Edit` / `⏸ Pause`\|`▶️ Resume` / `🗑` buttons (UX14, §9.3). |
| `/settimezone [tz]` | | Set timezone; smart parsing (city / IANA / UTC offset). Bare → common-zone button grid + `⌨️ Type city` (UX1). ⚠️ Echo the resolved zone back (UX18) and reschedule all schedules (issue H1, §12). |
| `/timezones` | | List common timezones with their current local time. |
| `/import` | | Prompt user to send a `.txt` file (one quote per line). See §6.4. |
| `/tags` | | List your tags with quote counts + per-tag manage buttons. |
| `/dnd` | | Do Not Disturb weekday toggler (`dnd:wd:<0-6>`) — the entry point §9.5 otherwise lacks (UX22). |
| `/stats` | | Your streak & collection stats (§9.6). |

⚠️ **Retired from the docs as primary commands (still parse as fallbacks, §8.5.3):**
`/tag <id> #name`, `/untag <id> #name`, `/fav <id>`, `/unfav <id>`, `/addimage <id>` — all replaced
by the per-quote action row / toggles (§8.5.2). `/cancel` is **reserved for aborting the current
multi-step flow** (Telegram convention + the §11 escape hatch), NOT for deleting a schedule (issue
UX23) — schedule removal is `sched:del:<id>` from `/schedules`.

⚠️ **`/delete [id]` id-mapping.** Use the real DB primary key as the id shown in `/list`, but
**always** resolve it through `user.quotes.find_by(id: n)` — never `Quote.find(n)`. A non-owned or
non-existent id then simply returns nil → reply "That quote's no longer here — [📋 see your list]"
(UX20), never raise, never touch another user's row. (Sequential per-user display numbers were
considered but rejected: they go stale/racy after any deletion — issue M2.)
⚠️ **`/delete` semantics will change later (issue N14):** MVP hard-destroys the row. §18's
public-sharing feature needs soft-delete for quotes that have public votes/forks — plan to swap
`destroy` for a `deleted_at` tombstone then (or introduce it now, see §4).

⚠️ **On-demand `/quote` delivery logging (issue N10).** When `/quote` sends a quote on demand,
**do** write a `quote_delivery` row, but with `delivery_schedule_id: nil`. Because the unique
index is `(user_id, delivery_schedule_id, local_date)` and SQLite treats NULLs as distinct, these
rows never collide with each other or with a scheduled delivery — i.e. on-demand deliveries are
**not** deduped (a user can `/quote` many times a day). Decisions to honor consistently:
- On-demand deliveries **do** bump `quote.times_delivered` / `last_delivered_at` (they feed the
  least-recently-delivered weighting in §9.2).
- On-demand deliveries **do NOT** advance the daily streak (§9.4) — only scheduled deliveries do,
  otherwise a user trivially games the streak. Stats (§9.6) may count both but should label them
  separately. Keep this rule in one place and test it.

### 6.2 Confirm-on-text (primary capture flow) ⚠️ signature feature
Any plain text message that is **not** a command and **not** an expected state input should
trigger a confirmation prompt rather than being ignored:

1. Generate a short random **token** (e.g. 8 hex chars). Store the candidate text in Solid Cache:
   key `"pending_quote:#{token}"`, value `{ from_id:, chat_id:, text: }`, `expires_in: 10.minutes`.
   ⚠️ **Store the sender's user id (`from.id`) as `from_id`, not just `chat_id` (issue N12).** In a
   group chat `chat_id` is the group's id while `from.id` is the person — they are never equal, so
   an ownership check that compares a stored `chat_id` to the callback's `from.id` would reject the
   legitimate sender. Keep `chat_id` too (you need it to know where to reply), but do ownership on
   `from_id`. (MVP is designed for 1:1 DMs; storing `from_id` makes the group case correct for
   free and future-proofs it.)
   ⚠️ **Key by token, not by `chat_id`** (issue M1). If you key by chat_id, two quick messages
   overwrite each other and the user ends up adding the wrong text. The token binds a specific
   button to a specific candidate.
2. Reply with an inline keyboard: `✅ Add as quote` / `❌ Not a quote`.
   - ⚠️ Label the decline `❌ Not a quote` (UX6) so it's clear it dismisses the *save*, not the
     message (❌ is reused elsewhere for cancel).
   - Callback data: `qc:yes:#{token}` and `qc:no:#{token}` (well under the 64-byte limit).
3. On callback:
   - ⚠️ **Ownership check:** load the cached entry and verify its stored `from_id` equals the
     callback's own `from.id` (issue N12). Prevents user A tapping a button meant for user B in a
     group.
   - On `yes`: read the cached text, create the quote (scoped to the user), delete the cache key.
     ⚠️ **Then `edit_message_text` into a success card with next-action buttons (issue UX4)** —
     don't dead-end at a bare count. The just-added quote is the highest-intent moment to tag/fav:
     ```
     ✅ Saved (quote #3 of 20)
     [🏷 Tag] [❤️ Favourite] [🗑 Undo]
     cb: q:tag:<id> · fav:toggle:<id> · q:del:<id>
     ```
     `🗑 Undo` (not a bare delete) covers accidental saves. No id typed — the buttons carry the new
     id (§8.5.2).
   - ⚠️ **First-ever capture (0→1 quotes) upsell (issue UX5):** append "Want one delivered daily?
     [⏰ Set daily time]" (`sched:new`) to the success card, tying into the deferred onboarding
     schedule step (UX2, §11). Contextual, not a config chore.
   - On `no`: delete the cache key, dismiss politely.
   - ⚠️ **Expiry / missing cache:** if the key is gone (TTL elapsed), respond "That quote expired,
     please send it again" — never crash on `nil`. NOTE: Solid Cache is **DB-backed and survives
     app restarts** (issue M3) — the only reason a key disappears is the 10-minute TTL, so don't
     tell the user "the server restarted".
   - Always call `answer_callback_query` so Telegram stops the button's loading spinner.

**Interaction with state machine:** If the user is mid-onboarding (e.g. `awaiting_timezone`),
plain text must be interpreted as the **state input**, not as a new quote. Route state inputs
first (§11), fall through to confirm-on-text only in the `ready`/no-pending-state case.
⚠️ This ordering is the single most common bug source — write explicit tests for
"text while awaiting_timezone" vs "text while ready".

### 6.3 `/list` pagination (button-driven — see §8.5.4)
- Page size 10 (configurable constant).
- Order by `created_at ASC` so the per-user sequential id is stable.
- ⚠️ **Two-tier browse (issue UX11):** footer keyboard `⬅️` · `n/total` · `➡️` (`list:pg:<n>`),
  second row `🏷 Filter by tag` (`list:tags`) + `🎲 Random` (`q:rand:0`). Render items numbered
  `1.`…`10.` with a row of number buttons `[1][2]…` (`q:show:<id>`) that open a **single-quote
  detail card** carrying the full per-quote action row (§8.5.2). This detail card is the concrete
  home for the previously-deferred "`/show [id]`" — build it now as the tap target so ids are
  never typed.
- ⚠️ Edit the existing message (`edit_message_text`) on page change rather than sending a new
  message each time, to avoid chat spam. Handle "message is not modified" API error silently.
- ⚠️ Telegram messages cap at 4096 chars — truncate long quotes in the **list** view (short
  preview); show full text in the `q:show` detail card (still under 4096). Keep each page under
  the cap.
- Tag filter carries through paging via `list:pg:<n>:<tag_id>` (§8 namespace).
- ⚠️ Empty collection (issue UX12) → "You have no quotes yet — send me one!" **plus** action
  buttons `[📥 Import a file] [🎲 See an example]` so the empty state teaches both capture paths.

### 6.4 Import from text file
- User sends a document; the webhook/poll update contains a `document` with a `file_id`.
- ⚠️ MVP: **restrict to `.txt`/plain text**, and cap file size (e.g. 256 KB) and line count
  (e.g. 500 lines, or the free-tier limit) — reject oversized files with a clear message.
- Download via Telegram `getFile` → `file_path` → `https://api.telegram.org/file/bot<token>/<path>`.
  ⚠️ The download URL contains the bot token — never log it.
- Parse one quote per non-blank line; trim whitespace; skip lines shorter than the min length;
  de-duplicate against existing content (optional).
- Import inside a transaction or in batches; report "Imported N quotes (skipped M)".
- ⚠️ Encoding: force UTF-8 and scrub invalid bytes (`str.encode("UTF-8", invalid: :replace,
  undef: :replace)`) or the whole import can blow up on one bad byte.
- Store "awaiting import file" as a `state` or a short-lived cache flag so a stray document
  isn't misinterpreted.

### 6.5 QuotePresenter
Small service that formats a quote (and the "daily quote" wrapper):
- `"content"` on its own line; `— author` if present; ` (source)` if present.
- Provide two variants: `#message_text` (for `send_message`, 4096-char budget) and
  `#caption_text` (for `send_photo`, **1024-char budget** — see §6.6).
- Escape user content for the chosen `parse_mode`. ⚠️ If you use `parse_mode: HTML`, you MUST
  HTML-escape user text (`ERB::Util.html_escape`) or a quote containing `<`, `>`, `&` breaks the
  message and can inject markup. Safest MVP choice: **send with no `parse_mode`** (plain text)
  for user-generated quote content, and only use formatting for bot chrome. Decide once,
  document it, and test with a quote like `A < B & "C" > D`.

### 6.6 Image attachments (feature) 📷
A quote may optionally have a photo. Storage is **dual**: the Telegram `file_id` (for zero-cost
re-sends) **and** an Active Storage attachment (durable copy; S3 in prod — see §13).

**Why both:** re-sending by `file_id` needs no upload and is instant, but `file_id` is only
usable through the Bot API (not on a future web/public page) and, while stable in practice, is
not contractually permanent. Active Storage gives a durable, web-usable copy and enables future
V3 image-card / public-page features. On capture we store `file_id` immediately and download to
Active Storage in the background.

**Capture flows** (all create/attach scoped to `user`):
- **Photo + caption** → treat like confirm-on-text but for a photo: cache
  `{ chat_id:, file_id:, caption: }` under `pending_photo_quote:#{token}` (10 min), prompt
  "Add as quote with this image?" with `✅ / ❌`. On yes: create quote with `content = caption`,
  `photo_file_id = file_id`, enqueue `AttachQuoteImageJob`.
- **Photo, no caption** → cache the `file_id` under `pending_photo:#{token}`, set state
  `awaiting_quote_text_for_photo`, ask for the quote text. Next text message becomes the content.
- **`/addimage <id>`** → resolve `user.quotes.find_by(id:)`; if found, set state
  `awaiting_image_for_quote` + cache the target quote id; the next photo attaches to it.

⚠️ **Always take the largest size.** Telegram sends `photo` as an array of increasing-resolution
`PhotoSize`s. Use `photo.last[:file_id]` (or the max by `file_size`). Using the first gives a
tiny thumbnail. Update `Bot::UpdateParser` to extract `photo` (array) and `document` for image
documents.

**`AttachQuoteImageJob(quote_id)`** — downloads the Telegram file and attaches it to Active
Storage:
- `getFile(file_id)` → `file_path` → download from
  `https://api.telegram.org/file/bot<token>/<file_path>`. ⚠️ **Never log this URL** — it embeds
  the bot token.
- ⚠️ Telegram `getFile` only works for files up to **20 MB**; photos are fine, but guard and
  skip gracefully on failure (the `file_id` is still stored, so delivery still works).
- Attach via `quote.image.attach(io:, filename:, content_type:)`. Retry on transient download
  errors; on permanent failure just log — image delivery falls back to `file_id`.

**Delivery** (on-demand and scheduled — see §7):
- If `quote.photo_file_id.present?` (or an attached image) → `send_photo(chat_id, photo:
  file_id, caption: presenter.caption_text)`.
- ⚠️ **Caption limit is 1024 chars**, not 4096. If the formatted quote exceeds it, send the photo
  with a truncated/empty caption, then the full text as a follow-up `send_message`.
- ⚠️ **`file_id`-invalid fallback (issue N6) — get the mechanics right.** `file_id`s can expire
  or become invalid. If `send_photo(photo: file_id)` fails with a `file_id`-invalid/bad-request
  error, fall back in this order:
  1. If an Active Storage image is attached: `blob.download` into a `Tempfile` (binary mode) and
     `send_photo` that file as a **multipart upload** (not a URL/`file_id`). ⚠️ Verify the
     `TelegramClient` facade actually supports multipart photo uploads — telegram-bot-ruby takes a
     `Faraday::UploadIO`/`File`; if the facade only forwards a string `file_id`, extend it. After a
     successful re-upload, **capture the new `file_id` from the response and update
     `quote.photo_file_id`** so subsequent sends are cheap again.
  2. If no Active Storage image exists (download job failed / skipped): send the quote **text-only**
     and log.
  Delivery must never hard-fail because an image went missing.

**Not gated:** images are available to all users for now (no free-tier limit — per product
decision). Import-from-file stays text-only.

---

### 6.7 `/settings` — user control panel (issue UX21)
`/settings` is a **button-driven control panel**, the app's home screen — NOT a text dump. (This
is the *user* settings; the *admin* dashboard is the separate §10.)
- One-line status header + a button grid:
  ```
  ⚙️ Settings
  Quotes: 14/20 · TZ: Europe/London (14:35) · 2 schedules

  [🌍 Timezone]  [⏰ Schedules]
  [🏷 Tags]      [🌙 Do Not Disturb]
  [📊 Stats]     [📥 Import]
  cb: set:tz · set:sched · set:tags · set:dnd · set:stats · set:import
  ```
- Each button routes to the existing manager (e.g. `set:sched` → the `/schedules` view, `set:dnd`
  → the §9.5 weekday toggler, `set:tz` → the timezone picker). Reuse handlers; don't duplicate.
- This turns settings into the primary navigation surface and further reduces command typing.

## 7. Scheduling & delivery (schedule-centric, self-rescheduling + safety net)

We keep eye_on_sky's **self-rescheduling job + daily safety net** shape, but with two deliberate
improvements over the reference (which the design review flagged):

1. **The scheduling unit is a `delivery_schedule` row, not a user.** Each schedule owns at most
   one pending `DeliverQuoteJob`. This is what makes per-tag schedules (deliver `#motivation` at
   08:00 and `#movie` at 21:00) fall out naturally, and it's forward-compatible from MVP (where a
   user has exactly one schedule with `tag_id: nil`).
2. **Each schedule stores its own `pending_job_id`.** We do NOT scan `SolidQueue::Job`
   arguments in Ruby the way eye_on_sky does — that is O(N) per call and O(N²) across the 2am
   safety net (issue C1). Instead, cancellation and "is there a pending job?" are **indexed
   lookups** by the stored job id.

### 7.1 `QuoteScheduler` (module, keyed by schedule)
- `schedule_for(schedule)`:
  1. `cancel_pending_for(schedule)` — discard the job referenced by `schedule.pending_job_id`
     (if any), then null the column.
  2. Compute `run_at = next_run_time(schedule)`.
  3. ⚠️ **Persist the id before/with enqueue, not after (issue N5).** Do NOT enqueue and then
     `update!` the column in a second step — a near-now job (same-day reschedule, or in tests)
     can start and run the §7.2 stale-job guard *before* the id is persisted, wrongly abort, and
     silently deliver nothing. Instead: build the job, capture `job.job_id`, and write
     `pending_job_id` **in the same DB transaction that enqueues** — e.g. wrap
     `DeliverQuoteJob.set(wait_until: run_at)` + the `schedule.update!(pending_job_id:)` in a
     `transaction`, or assign the id and enqueue such that the row is committed before the job
     can be claimed. (SolidQueue polls to claim, so committing the id in the same transaction as
     the enqueue closes the window.)
  - Only schedule if `schedule.enabled?` and `schedule.user.active?` and the user has a timezone.
- `next_run_time(schedule)`: in the **user's** timezone, today at `hour:minute` if still future,
  else tomorrow. ⚠️ Use `ActiveSupport::TimeZone[user.timezone].local(...)`, never manual offset
  math (breaks across DST).
  - ⚠️ **DST gap (issue N3 — the earlier M6 remediation was WRONG):** a non-existent local time
    (e.g. `02:30` on a spring-forward day) is **not** raised by `TimeZone#local` — Rails already
    auto-resolves it to the shifted instant (`America/New_York` `02:30` → `03:30 EDT`). **Accept
    that resolved instant as-is.** Do NOT "bump by an hour if the hour differs" — that
    double-corrects to 04:30. No special handling is needed beyond a test asserting the resolved
    time is accepted verbatim.
- `cancel_pending_for(schedule)`: if `pending_job_id` present, find the **live** job
  ⚠️ `SolidQueue::Job.where(active_job_id: pending_job_id, finished_at: nil)` (issue N4 — see
  below), and `discard` it if it's not claimed; then clear the column. Do not blow up if no live
  row exists.
- `pending_job_exists_for?(schedule)`: true iff a **live** (`finished_at: nil`, not
  failed-execution) job row exists for `pending_job_id`. A *claimed* (currently running) job
  **counts as pending** here (issue C2). A *failed* one does not (so the safety net recovers it).

⚠️ **`active_job_id` is not unique across retries (issue N4).** `retry_on` re-enqueues with the
**same** `active_job_id`, and SolidQueue inserts a **new** `solid_queue_jobs` row per retry while
the previous row remains `finished`. So `find_by(active_job_id:)` is ambiguous and may return a
finished row → false "not pending" → the 2am net enqueues a duplicate, or `cancel` discards the
wrong row. **Always scope by `finished_at: nil`** (and expect 0-or-more, not exactly one). Because
of this, correctness does NOT rest on the lookup alone — the §7.2 stale-job guard is the real
backstop. The lookup is an optimization to avoid scanning, not a guarantee.

⚠️ **`pending_job_id` bookkeeping is the invariant.** Every path that enqueues a DeliverQuoteJob
must write the new id (committed with the enqueue, N5), and every path that discards one must
clear it. The job itself writes its successor's id when it reschedules (§7.2).

### 7.2 `DeliverQuoteJob(schedule_id, date_str)`
- Reload the schedule (AR); bail cleanly if it's gone, disabled, or the user is inactive.
- ⚠️ **Duplicate/stale-job guard (the real fix for C2, backstops N4/N5):** compare
  `self.job_id` (ActiveJob exposes `job_id` inside `perform`; it is the enqueued id and is
  **preserved across `retry_on` retries**) to `schedule.pending_job_id`. **If they differ, this
  is a stale or duplicate job — return immediately without sending.** This makes a double-send
  impossible even if the ambiguous lookup (N4) or the write-after-enqueue race (N5) let a second
  job slip through. ⚠️ Because the *same* `job_id` survives retries, a retry of the legitimate
  job still matches and proceeds — the guard does not swallow retries.
- Select a quote **from the schedule's scope**:
  - `tag_id` nil → `user.quotes`; else → quotes tagged with that tag (`user.quotes.joins(:tags)
    .where(tags: { id: schedule.tag_id })`).
  - Weighted random for V2 (favourites boost + least-recently-delivered) — see §9.2.
- ⚠️ **Empty scope (fixes H3):** if the scope has no quotes, **do not early-return** — skip the
  send but still reschedule this schedule for tomorrow, so it isn't stranded until 2am. (A
  tag-scoped schedule whose tag is currently empty must keep ticking.)
- Send via `TelegramClient` (`send_message`, or `send_photo` if the quote has an image — §6.6).
  ⚠️ **Attach the standard delivery action row (issue UX15/§8.5.2):**
  `❤️ Fav · 🎲 Another · 😴 Snooze today` (`fav:toggle:<id>` · `q:rand:<schedule_id>` ·
  `dnd:today`). `🎲 Another` sends another quote from the **same schedule's scope** (pass the
  schedule id; `0` for on-demand `/quote`). Expose 🏷/🗑/📷 inside the `q:show` detail card rather
  than crowding the delivery card.
- After a successful send: bump `times_delivered`, set `last_delivered_at`, write a
  `quote_delivery` row (`local_date` in the user's tz, `delivery_schedule_id: schedule.id`;
  rescue `RecordNotUnique` per §4/N1), and update the streak (§9.4).
- **Reschedule the next day** via `QuoteScheduler.schedule_for(schedule)` — wrapped in a rescue so
  a scheduling hiccup can never fail an already-completed send.
  - ⚠️ **Reload the schedule first** — the user may have changed its time/tag while the job ran.
- `retry_on TelegramClient::Error, wait: 30.seconds, attempts: 3`; on exhaustion, reschedule the
  schedule for tomorrow so a transient outage never permanently strands it.
- `rescue TelegramClient::Forbidden` → `user.update!(active: false)`; do not reschedule.

⚠️ **Ordering rule:** the only automatic retry must be able to fire **before** the message is
sent (so it can't double-send). Everything after the send (log, streak, reschedule) is wrapped so
it never raises out of the job.

### 7.3 `ScheduleQuotesJob` (daily safety net)
- Recurring at 2am (see §7.4).
- Iterates **enabled schedules** whose user is `active` and has a timezone, and for which
  `pending_job_exists_for?(schedule)` is false, and calls `QuoteScheduler.schedule_for(schedule)`.
  Recovers schedules whose job was lost to a restart or exhausted its retries.
- ⚠️ **A failed job must NOT count as pending** (else stranded schedules never recover), and — per
  C2 — **a claimed/running job MUST count as pending** (else the net enqueues a duplicate while
  the running job is about to reschedule). Both fall out of the `pending_job_exists_for?`
  definition in §7.1; the stale-job guard in §7.2 is the belt-and-suspenders backstop.
- ⚠️ This query must be efficient at scale: iterate `DeliverySchedule.where(enabled: true)
  .joins(:user).merge(User.active).where.not(users: { timezone: nil })` and check the indexed
  `pending_job_id` — no per-schedule scan of the jobs table (issue C1). Add a supporting index on
  `delivery_schedules(enabled, user_id)` (issue L2).

### 7.4 Triggers that must (re)schedule
⚠️ Missing reschedules are issue H1/H3. Call `QuoteScheduler.schedule_for(schedule)` (or
`cancel_pending_for`) on **every** mutation that affects delivery:
- Creating/updating a schedule's time or tag (`/schedule`).
- Enabling a schedule; **disabling** → `cancel_pending_for` + `enabled: false`.
- Changing the user's **timezone** (`/settimezone`) → reschedule **all** the user's schedules (§12).
- Adding the user's **first quote** while a schedule exists but was skipped for emptiness →
  reschedule affected schedules (or just let the 2am net catch it, but prefer immediate).
- Deleting a **tag** → its tag-scoped schedules are destroyed (`dependent: :destroy`); call
  `cancel_pending_for` on each first so no orphan job fires.

### 7.5 Recurring config
`config/recurring.yml` — ⚠️ include **both** `production:` and `development:` blocks (issue M7),
mirroring eye_on_sky (dev omission means the safety net silently never runs in dev):
```yaml
production: &shared
  clear_solid_queue_finished_jobs:
    command: "SolidQueue::Job.clear_finished_in_batches(sleep_between_batches: 0.3)"
    schedule: every hour at minute 12
  schedule_quotes:
    class: ScheduleQuotesJob
    queue: default
    schedule: at 2am

development:
  <<: *shared
```

---

## 8. Callback data conventions
- Namespaced, colon-delimited, all **≤ 64 bytes**. Reference entities by **numeric id**, never by
  name/free text.
- ⚠️ **Locked namespace table (issue UX25) — every prefix has exactly one meaning:**

  | Prefix | Meaning | Examples |
  |---|---|---|
  | `qc:` | confirm-on-text decision | `qc:yes:<token>` / `qc:no:<token>` (§6.2) |
  | `pc:` | confirm-on-photo decision | `pc:yes:<token>` / `pc:no:<token>` (§6.6) |
  | `q:` | act on / return **a quote** | `q:show:<id>` (detail card), `q:del:<id>`→`q:dely:<id>`/`q:deln:<id>` (delete+confirm), `q:tag:<id>` (open tag picker for a quote), `q:img:<id>` (attach image), `q:rand:<sched_id\|0>` ("another"), `q:bytag:<tag_id>` (**random from a tag** — renamed from the old `q:tag:<tag_id>` to remove the collision), `q:pub:<id>` (reserve for §18 share) |
  | `fav:` | favourite toggle | `fav:toggle:<quote_id>` |
  | `tag:` | tag ops | `tag:add:<quote_id>:<tag_id>`, `tag:rm:<quote_id>:<tag_id>`, `tag:new:<quote_id>`, `tag:dely:<tag_id>`/`tag:deln:<tag_id>` (delete-tag confirm) |
  | `list:` | pagination / browse | `list:pg:<n>`, `list:pg:<n>:<tag_id>`, `list:tags` (open tag filter) |
  | `sched:` | schedule builder/manager | `sched:new`, `sched:tag:<tag_id\|any>`, `sched:h:<HH>`, `sched:m:<MM>`, `sched:time:<HHMM>`, `sched:toggle:<id>`, `sched:edit:<id>`, `sched:del:<id>` |
  | `set:` | settings control panel | `set:tz`, `set:sched`, `set:tags`, `set:dnd`, `set:stats`, `set:import` (§6.1/§10, UX21) |
  | `dnd:` | Do Not Disturb | `dnd:wd:<0-6>` (weekday toggle), `dnd:today` (snooze today) |
  | `tz:` | timezone picker | `tz:idx:<i>` (index into cache-stored list, §12), `tz:type` (switch to typed input) |
  | `ob:` | onboarding steps | `ob:tz`, `ob:addfirst`, `ob:help` (§11, UX1) |
  | `disc:`/`vote:`/`fork:`/`report:` | future public feed | reserved (§18, UX27) |

  ⚠️ **The old `q:tag:<tag_id>` "quote from this tag" callback is renamed to `q:bytag:<tag_id>`**
  because `q:tag:<quote_id>` now opens the per-quote tag picker. Do not reuse `q:tag` for the
  filter.
- ⚠️ Telegram limits callback_data to **64 bytes**. Long IANA timezone names or tag names can
  blow this — that's why timezones use an index (`tz:idx:3`) into a cache-stored option list, and
  tags/schedules are referenced by id. Never stuff a name into callback data.
- Always validate/parse callback data defensively; unknown patterns → `answer_callback_query`
  (no-op) and log at debug.
- ⚠️ Call the gem/facade methods in **snake_case** (`answer_callback_query`, `edit_message_text`)
  — the Bot API's camelCase names appear only in prose here (issue L4).
- ⚠️ **Always pass a short toast text to `answer_callback_query` for state-changing taps (issue
  UX17)** — not just an empty spinner-clear. Toggles that don't visibly change the message
  (favourite, pause/resume, snooze) must confirm with text ("❤️ Favourited", "⏸ Paused", "😴
  Skipping today") or the tap feels like a no-op. Empty is fine only for pure navigation.

---

## 8.5 Interaction & UI design — button-first conventions ⚠️ (UX review)

QuoterBack is **button-first**: slash commands exist and keep working, but a normal user should be
able to operate the bot almost entirely by tapping. Typing a numeric id is never required. These
conventions apply across all features; individual sections reference the `UXn` ids below.

### 8.5.1 Native command menu — `setMyCommands` (UX7)
- Register a curated command list on deploy via a new rake task `bot:set_commands` (add it next to
  `bot:set_webhook` in `lib/tasks/bot.rake`, §3; call it in the post-deploy step §16/§14).
- Keep it to ~7 high-value, **zero-argument** entries so Telegram shows the persistent **☰ Menu**
  button:
  `quote` (random quote) · `list` (browse) · `schedules` (deliveries) · `tags` · `stats` ·
  `settings` · `help`.
- ⚠️ Argument-heavy commands (`/tag <id>`, `/delete <id>`, `/addimage <id>`) are **deliberately
  excluded** from the menu — they are button-driven (§8.5.3) and only remain as power-user text
  fallbacks. Only canonical names appear (not aliases — UX24): canonical `/quote` and `/list`.

### 8.5.2 The standard per-quote action row (UX9, UX15)
Every quote the bot renders (in `/quote`, `/list` detail, delivery, search) carries a compact
inline action row so ids stay internal:
```
🏷 Tag   ❤️ Fav   🗑        📷
cb:  q:tag:<id> · fav:toggle:<id> · q:del:<id> · q:img:<id>
```
- `q:tag:<id>` → tag picker: existing tags as buttons `tag:add:<id>:<tag_id>` (applied ones show ✓
  and tapping them fires `tag:rm:<id>:<tag_id>` — a **toggle**, so `/untag` is retired from docs as
  a normal path), plus `➕ New tag` → `tag:new:<id>` (sets a state to capture the name).
- `q:img:<id>` → replaces `/addimage <id>`; sets `awaiting_image_for_quote` for that id (§6.6).
- `q:del:<id>` → **confirm step** (never immediate — see UX16 / §8.5.5).
- `fav:toggle:<id>` → flips ❤️/🤍, echoed by editing the button + a toast (UX10, UX17). Single
  toggle replaces the `/fav`+`/unfav` pair.
- ⚠️ Button budget: on the **delivery** card use `❤️ Fav · 🎲 Another · 😴 Snooze today` (UX15,
  §7.2); expose 🏷/🗑/📷 inside the `q:show` detail card instead of crowding every delivery.

### 8.5.3 Retiring typed-id commands (UX9, UX10)
`/tag <id> #name`, `/untag <id> #name`, `/delete <id>`, `/addimage <id>`, `/fav <id>`, `/unfav <id>`
all still parse (safe fallbacks, §6.1) but are **not** the documented primary interface. The
`/help` and command menu present the button-driven flows. Prefer single toggling buttons over
verb/anti-verb command pairs.

### 8.5.4 `/list` browse pattern (UX11, §6.3)
Two-tier browse, all via `edit_message_text` on one message:
- Footer keyboard: `⬅️` · `2/5` · `➡️` (`list:pg:<n>`); second row `🏷 Filter by tag` (`list:tags`)
  + `🎲 Random` (`q:rand:0`).
- Render items numbered `1.`…`10.`; a row of number buttons `[1][2]…` (`q:show:<id>`) opens a
  **single-quote detail card** (full text, respecting the 4096 cap) carrying the full action row
  (§8.5.2). This is the home for the deferred "`/show [id]`" — build it now as the tap target.
- Tag filter carries through paging via `list:pg:<n>:<tag_id>`.

### 8.5.5 Destructive-action confirmations (UX16)
MVP has no soft-delete (§4), so guard every destroy:
- Quote delete: `q:del:<id>` edits the message → "Delete this quote? [🗑 Yes, delete] [Cancel]"
  (`q:dely:<id>` / `q:deln:<id>`). For a **just-added** quote prefer lightweight `🗑 Undo` (UX4).
- Tag delete: name the blast radius **before** deleting (this satisfies §9.3's "tell the user
  which schedules were removed" — do it up front): "Deleting #movie also removes 2 schedules
  (09:00, 21:00). [Delete anyway] [Cancel]" (`tag:dely:<id>` / `tag:deln:<id>`).

### 8.5.6 Feedback, empty states & error tone (UX3, UX12, UX17, UX18, UX19, UX20)
- Every callback that changes state answers with a toast (§8, UX17).
- Echo normalized/resolved values back (UX18): tags (§9.1/N13), and timezone — after
  `/settimezone +9` reply "Timezone set to *Asia/Tokyo* (UTC+9), local 23:41" so the user sees the
  concrete zone chosen for an ambiguous offset (§12).
- Empty & error states always end in a tap, never a dead-end (UX12/UX19/UX20):
  - Empty list → `[📥 Import a file] [🎲 See an example]`.
  - Free-tier limit (§9.7) → "Reached the free limit of 20. Delete one to add more. [📋 Manage
    quotes]" (`list:pg:1`).
  - Invalid timezone (§12) → re-show the common-zone grid + `⌨️ Type city` (`tz:type`), not bare
    text.
  - Expired confirm (§6.2) → include `✍️ Add anyway` if the cached text is still retrievable.
  - `find_by` miss → "That quote's no longer here — [📋 see your list]".

### 8.5.7 Emoji & label vocabulary (UX6, UX25)
Reserve 🗑 for delete, ❌/✖️ for cancel/dismiss. The confirm-on-text decline is labelled
`❌ Not a quote` (UX6) so it clearly dismisses the *save*, not the message. Toggle buttons show the
**action they will perform** (`⏸ Pause` when enabled, `▶️ Resume` when paused — UX14), not the
current state.

---

## 9. V2 features (detailed)

### 9.1 Tags / categories (core of the tag feature)
- Data model: `tags` + `taggings` (see §4). Per-user namespace, normalized names.
- **Button-first tagging (issue UX9, §8.5.2):** the `🏷 Tag` button on any rendered quote
  (`q:tag:<quote_id>`) opens a picker of the user's tags. Applied tags show ✓ and tapping them
  **removes** the tag (`tag:rm:<quote_id>:<tag_id>`) — the picker is a toggle, so a separate
  `/untag` flow is unnecessary. Un-applied tags add (`tag:add:<quote_id>:<tag_id>`); `➕ New tag`
  (`tag:new:<quote_id>`) sets a state to capture the name. The `/tag`/`/untag` text commands
  remain only as power-user fallbacks (§8.5.3).
- Query by tag:
  - `/quote #motivation` → random quote from that tag. ⚠️ **Only a leading `#tag`, or a bare
    argument that *exactly matches* (after normalization) one of the user's existing tag names,
    filters by tag (issue N11).** Do NOT treat an arbitrary trailing word as a tag — `/quote love`
    when the user has no `love` tag must fall back to a normal random quote (or the "no such tag"
    message only if they typed the `#` prefix), never silently return "empty tag." Prefer the
    explicit `#` prefix; accept a bare word only on an exact tag-name hit.
  - Unknown tag (explicit `#name` with no match) → friendly "You have no quotes tagged
    #motivation yet."
  - A bare `/quote` may also render an inline row of the user's top tags (callback
    `q:bytag:<tag_id>` — ⚠️ renamed from `q:tag` to avoid colliding with the per-quote tag picker,
    issue UX25/§8) so users can pick a tag without typing.
  - `/list #motivation` → paginated, tag-filtered (`list:pg:<n>:<tag_id>` through the page
    callback).
- ⚠️ Adding an existing `(quote, tag)` is idempotent (unique index + `find_or_create_by`).
- ⚠️ **Tag name normalization must be visible, not silent (issue N13).** Normalize on the way in
  (strip leading `#`, downcase, collapse internal whitespace, trim). Because normalization can
  collapse distinct inputs onto one tag (`#Movie`, `movie`, `MOVIE` → `movie`), **echo the
  normalized name back** in every confirmation ("Tagged with #movie") so the user sees what was
  actually stored, and reuse the existing tag rather than appearing to create a new one. Reject
  empties/invalid characters with a clear message.
- ⚠️ Creating a tag is scoped to the user; `find_or_create_by!(user:, name:)` with a
  `rescue RecordNotUnique; retry` for the create race.

### 9.2 Favourites + weighted delivery
- Single inline ❤️/🤍 **toggle** on any rendered quote (`fav:toggle:<id>`, §8.5.2), echoed by
  editing the button + a toast (UX10/UX17). The `/fav`/`/unfav` command pair remains only as a
  power-user fallback (§8.5.3) — prefer the toggle.
- Weighted random selection in `DeliverQuoteJob`, computed **within the schedule's scope**
  (§7.2): give favourited quotes a higher weight (e.g. 3× vs 1×) and down-weight
  recently-delivered ones via `times_delivered` / `last_delivered_at`
  ("least-recently-delivered + favourite boost"). Keep it O(n)-friendly.

### 9.3 Per-tag schedules (the scheduling half of the tag feature)
The scheduling engine is already schedule-centric (§7), so this feature is mostly UX:
- A `delivery_schedule` has an optional `tag_id`. `tag_id: nil` = whole collection; set = only
  quotes with that tag. `DeliverQuoteJob` already selects from the schedule's scope (§7.2).
- `/schedule` — interactive builder (issue UX13), **buttons-first**:
  1. `sched:new` → "Deliver from which set?" → row of tag buttons + `[Any]`
     (`sched:tag:<tag_id>` / `sched:tag:any`).
  2. **Inline hour grid** (`sched:h:<HH>`) → **minute chooser** `:00 :15 :30 :45` (`sched:m:<MM>`),
     assembling into `sched:time:<HHMM>`. Carry the chosen tag in cache/state — do NOT stuff both
     tag and time into one callback. Free-typed `HH:MM` stays a fallback, not the default.
  3. Confirm: "📅 Daily at 09:00 · #motivation. [✅ Create] [✏️ Change] [Cancel]".
  Then calls `QuoteScheduler.schedule_for`.
- `/schedules` — list each schedule ("📅 09:00 · #motivation", "📅 21:00 · Any"), with per-row
  buttons (issue UX14): `✏️ Edit` (`sched:edit:<id>`, changes time/tag without delete-recreate),
  a **self-documenting** toggle (`⏸ Pause` when enabled / `▶️ Resume` when paused —
  `sched:toggle:<id>`, show the action not the state), and `🗑` (`sched:del:<id>`, confirmed per
  §8.5.5).
- Multiple schedules per user are supported (one pending job **per schedule**, keyed by
  `pending_job_id` — no cross-schedule interference; this is what fixes the critic's H4).
- ⚠️ Not gated: unlimited schedules for now (no free-tier cap — per product decision). The
  `FREE_QUOTE_LIMIT`-style stub in §9.7 does **not** apply to schedules or images.
- ⚠️ A tag-scoped schedule whose tag has 0 quotes skips its send but keeps rescheduling (§7.2).
- ⚠️ Deleting a tag destroys its tag-scoped schedules (`dependent: :destroy`), cancelling their
  pending jobs first (§7.4). **Confirm before deleting, naming the blast radius** (issue UX16 /
  §8.5.5) — "Deleting #movie also removes 2 schedules (09:00, 21:00)."

### 9.4 Streaks 🔥
- Derived from `quote_deliveries`: count consecutive **distinct local dates** with ≥1 delivery
  (issue M4 — count dates, not rows). Cache `streak_count` + `streak_last_date` on `users`,
  updated in `DeliverQuoteJob` after a successful send.
- ⚠️ "Consecutive days" is in the **user's timezone**. Update logic: if `local_date ==
  streak_last_date` → no change (already counted today); if `== streak_last_date + 1` →
  increment; else → reset to 1. A missed day resets.
- ⚠️ Beware timezone changes / DST: a user moving zones must not double-count or spuriously break
  a streak — always derive `local_date` from the user's *current* timezone at send time and rely
  on the `+1 day` comparison.

### 9.5 Do Not Disturb / custom days
- `dnd_weekdays` (bitmask or array of 0–6) on the user; `DeliverQuoteJob` skips delivery on DND
  days but **still reschedules** the following eligible day. ⚠️ Compute the weekday in the user's
  timezone.
- ⚠️ **Give it an entry point (issue UX22)** — the feature is otherwise unreachable. Add:
  - `/dnd` (and a `🌙 Do Not Disturb` button in `/settings`, `set:dnd`) → a **7-button weekday
    toggler** (`dnd:wd:<0-6>`, each showing ✅/⬜, toast on tap per §8.5.6).
  - `😴 Snooze today` on the delivery card (`dnd:today`, §7.2/UX15) → a transient one-day "skip
    next" flag for that schedule; confirm with an `answer_callback_query` toast, no chat spam.

### 9.6 Quote stats
- `/stats`: total quotes, distinct authors, top tags, current streak, quotes delivered.
- Backed by scoped aggregate queries (`user.quotes.count`, `group(:author)`, etc.).

### 9.7 Free-tier limit (STUB ONLY — no payments)
- Introduce a single constant `FREE_QUOTE_LIMIT = 20` and a `user.premium?` method that returns
  `false` for now (no payment integration).
- ⚠️ **Enforce at ONE choke point, not per command (issue N9).** Every quote is born through a
  single method — e.g. `QuoteCreator.call(user:, ...)` / `user.quotes.create!` wrapper. Put the
  `!user.premium? && user.quotes.count >= FREE_QUOTE_LIMIT` check **there**, so it cannot be
  bypassed. The earlier "check on /add" framing missed paths: the **photo-then-text** flow and the
  **`awaiting_quote_text`** state both create quotes without going through `/add`, and would slip
  past a command-level check. Routing all creation through the choke point covers direct `/add`,
  confirm-on-text yes, confirm-on-photo yes, and import in one place.
- For **import** (bulk), check remaining capacity before inserting and import only up to the cap,
  reporting how many were skipped. `/addimage` attaches to an existing quote (creates none) → exempt.
- ⚠️ **Limit-reached copy must offer a next action (issue UX19):** don't dead-end. "You've reached
  the free limit of 20 quotes. Delete one to add more. [📋 Manage quotes]" (`list:pg:1`). Since
  payments are a stub, point to the self-service remedy.
- ⚠️ **Schedules and images are NOT gated** (per product decision) — unlimited schedules, images
  free for everyone. Only the quote *count* stub above applies.
- Keep this behind a feature flag/constant so it's trivial to flip later.

---

## 10. Admin dashboard
Mirror eye_on_sky exactly:
- `Admin::DashboardController` with HTTP Basic Auth `before_action` using
  `ENV["ADMIN_USERNAME"]`/`ADMIN_PASSWORD` and `secure_compare` (copy verbatim). Blank creds →
  `head :forbidden`.
- `Admin::StatsQuery` service returning totals: users (total/active), quotes, deliveries today,
  users with scheduling enabled, top authors/tags. Optional `?date=` filter.
- Route under `namespace :admin` with `root to: "dashboard#index"`.
- ⚠️ Admin routes must be behind auth and excluded from any public caching. Do not expose
  per-user quote *content* in the dashboard beyond aggregate counts (privacy) unless explicitly
  needed for support.

---

## 11. Onboarding state machine
Model conversation state on `users.state` (string), validated against a `STATES` constant, like
eye_on_sky. States:
`new`, `awaiting_timezone`, `awaiting_schedule_time`, `awaiting_quote_text`,
`awaiting_quote_text_for_photo`, `awaiting_image_for_quote`, `awaiting_import_file`, `ready`.

- `/start` on a `new` user → welcome message ending in a **tap-only** inline keyboard, no typing
  required to progress (issue UX1):
  `🌍 Set my timezone` (`ob:tz`) · `✍️ Add my first quote` (`ob:addfirst`) · `❓ How it works`
  (`ob:help`).
  - The timezone step (`ob:tz`) shows a grid of ~8 common zones (`tz:idx:<i>`) + `⌨️ Type my city`
    (`tz:type`, sets `awaiting_timezone`). Golden path = 3 taps, zero typing.
  - ⚠️ **Defer the schedule step (issue UX2):** do NOT force a daily-time choice during onboarding
    (the collection is empty, so the first delivery has nothing to send). After timezone, jump
    straight to "send me your first quote", and offer scheduling *after* the first capture via the
    `⏰ Set daily time` button on the success card (UX5, §6.2).
  - ⚠️ **Terminal confirmation (issue UX3):** on reaching `ready`, send an explicit "✅ You're set
    up! Timezone: *Europe/London*. Send me any message and I'll offer to save it. Tap ☰ Menu
    anytime." with a `📖 Show commands` button — don't leave the user guessing that onboarding
    ended.
- ⚠️ Every state handler must accept a `/command` as an **escape hatch** — if a user types
  `/quote` while `awaiting_timezone`, honor the command (or at least re-prompt), never trap them.
  `/cancel` explicitly aborts the current flow and clears state (issue UX23).
- ⚠️ Guard `find_or_create_from_update!` against the `RecordNotUnique` race (two rapid updates)
  with `rescue ActiveRecord::RecordNotUnique; retry` — copy eye_on_sky's method.
- ⚠️ **Reserve `/start` payload parsing (forward-compat, §18):** Telegram deep links deliver a
  payload as the text after `/start` (`/start q_<public_id>`). Write the `/start` handler to read
  an optional payload from day one (ignore unknown payloads) so the future "open a shared quote"
  deep link slots in without refactoring onboarding.
- ⚠️ Transient per-conversation payloads (pending quote token, pending photo file_id, target
  quote id for `/addimage`) live in **Solid Cache keyed by token**, not on the user row; only the
  coarse `state` string is persisted (§4).

---

## 12. Timezone handling ⚠️
- Store IANA names only (`Europe/London`). Validate with `ActiveSupport::TimeZone[tz]` (nil =
  invalid) in a model validation.
- Smart input parsing (`/settimezone` and onboarding):
  1. Exact IANA match.
  2. City/name match against `ActiveSupport::TimeZone` mapping (case-insensitive).
  3. UTC offset like `+9`, `-5` → pick a representative zone at that offset. ⚠️ **Echo the
     resolved zone back (issue UX18):** "Timezone set to *Asia/Tokyo* (UTC+9), local 23:41" so the
     user sees the concrete zone chosen for an ambiguous offset.
  4. Fallback: ask again — ⚠️ **re-show the common-zone button grid + `⌨️ Type city` (issue
     UX19)**, not a bare text re-prompt. Do **not** silently default to UTC after an explicit
     attempt.
- All scheduling math uses `ActiveSupport::TimeZone#local` / `#in_time_zone`. Never manual offset
  addition (DST).
- ⚠️ **Changing the timezone must reschedule ALL of the user's schedules** (issue H1): after a
  successful `/settimezone`, iterate `user.delivery_schedules.where(enabled: true)` and call
  `QuoteScheduler.schedule_for(schedule)` on each. Otherwise pending jobs keep firing at the old
  local time until the 2am safety net.
- `/timezones` lists a curated set with each zone's current local time.

---

## 13. Configuration files (copy from eye_on_sky, rename)
- `config/database.yml` — multi-db (primary/cache/queue/cable), storage/ paths.
  - ⚠️ **SQLite write contention (issue M5/N8):** the primary DB is written by both the web
    process (quote creation) and the in-Puma `DeliverQuoteJob` (`times_delivered`, delivery log,
    streak). WAL mode + a `busy_timeout` (Rails 8's SQLite adapter enables WAL and honors
    `timeout:`, already `5000`ms in the reference) reduces lock errors but **does NOT serialize
    writers** — WAL still allows only one writer at a time, so a genuinely concurrent write can
    still hit "database is locked" once the busy_timeout elapses. Therefore make these **firm
    requirements**, not nice-to-haves:
    - Every write transaction must be **tiny and short-lived** — never do network I/O (a Telegram
      send) or heavy computation inside an open write transaction. Send first, then open a brief
      transaction to record the result.
    - Prefer routing DB writes through the **single in-Puma Solid Queue worker** (jobs are the
      write path for deliveries) rather than doing them inline in the web request where avoidable.
    - Verify the pragmas via a connection check (`PRAGMA journal_mode=WAL; PRAGMA
      busy_timeout=5000;`) and add a test that concurrent create + delivery write does not raise.
    - If lock errors still appear under load, fall back to a dedicated single-threaded write queue.
- `config/queue.yml`, `config/cache.yml`, `config/cable.yml` — defaults are fine.
- `config/storage.yml` — Active Storage services (issue: image feature §6.6):
  ```yaml
  local:
    service: Disk
    root: <%= Rails.root.join("storage") %>
  amazon:
    service: S3
    access_key_id:     <%= ENV["AWS_ACCESS_KEY_ID"] %>
    secret_access_key: <%= ENV["AWS_SECRET_ACCESS_KEY"] %>
    region:            <%= ENV["AWS_REGION"] %>
    bucket:            <%= ENV["AWS_S3_BUCKET"] %>
  ```
  - `config/environments/development.rb` + `test.rb`: `config.active_storage.service = :local`.
  - `config/environments/production.rb`: `config.active_storage.service = :amazon`.
  - Add `gem "aws-sdk-s3", require: false` to the Gemfile. ⚠️ In dev the `storage/` dir sits in
    the same tree as the SQLite DBs (already the Kamal volume) — fine; in prod images go to S3 so
    they are **not** on the SQLite volume.
- `config/environments/production.rb`: ⚠️ `config.assume_ssl = true` and `config.force_ssl =
  true` (required because kamal-proxy terminates SSL). Without these, redirect loops / insecure
  cookies. `/telegram/webhook` still works over the proxy (POST is fine).
- `config/routes.rb`:
  ```ruby
  get  "up" => "rails/health#show", as: :rails_health_check
  post "telegram/webhook" => "telegram_webhooks#create"
  namespace :admin do
    root to: "dashboard#index"
    get "dashboard" => "dashboard#index"
  end
  ```
- `config/initializers/rollbar.rb` — copy.
- ⚠️ `config/initializers/webhook_secret_check.rb` (issue L1/N2): in production, raise if
  `ENV["TELEGRAM_WEBHOOK_SECRET"]` is blank, so a misconfigured deploy can't silently run with
  webhook auth disabled. **But do NOT raise during asset precompilation / image build (issue N2).**
  `assets:precompile` runs in the Dockerfile under `RAILS_ENV=production` with
  `SECRET_KEY_BASE_DUMMY=1` and **no** real secrets present — an unconditional boot-raise there
  breaks `docker build`. Guard it: `next if ENV["SECRET_KEY_BASE_DUMMY"].present?` (and only check
  when `Rails.env.production?`). This still fails a real production **boot** (where
  `SECRET_KEY_BASE_DUMMY` is unset) but lets the build proceed. Alternatively defer the check to
  the first webhook request. Test both: build-time (dummy set → no raise) and runtime (dummy
  unset, secret blank → raise).
- `config/recurring.yml` — see §7.5 (⚠️ include the `development:` block, issue M7).
- `.env.example` — `TELEGRAM_BOT_TOKEN`, `TELEGRAM_WEBHOOK_SECRET`, `ADMIN_USERNAME`,
  `ADMIN_PASSWORD`, `ROLLBAR_ACCESS_TOKEN`, and (image feature) `AWS_ACCESS_KEY_ID`,
  `AWS_SECRET_ACCESS_KEY`, `AWS_REGION`, `AWS_S3_BUCKET`. ⚠️ Dev must use a **separate dev bot
  token**; dev Active Storage uses `:local`, so AWS vars can be blank in dev.
- `Procfile.dev`:
  ```
  web: bin/rails server -p ${PORT:-3000}
  jobs: bin/jobs
  bot: bin/rails bot:poll
  ```

---

## 14. Deployment with Kamal (same server as eye_on_sky) ✅

**Confirmed feasible.** eye_on_sky deploys via **kamal-proxy**, which is explicitly designed to
host **multiple apps on one server**, routing by `Host` header. The new bot coexists cleanly.

### 14.1 What makes multi-app work
- kamal-proxy (installed on the server by the first `kamal deploy`, shared across apps) listens
  on 80/443 and routes by the `proxy.host` value. Each app registers its own host.
- Each app is a **separate Docker container** with a **unique `service` name**; they do **not**
  publish host ports directly (the proxy handles ingress), so **no port conflict**.
- Each app gets its **own named Docker volume** for its SQLite storage → data isolation.

### 14.2 `config/deploy.yml` for quoterback_bot (differences from eye_on_sky in **bold**)
```yaml
service: quoterback_bot                      # ← unique
image: borisano/quoterback_bot               # ← unique
servers:
  web:
    - 52.17.14.111                           # ← SAME server as eye_on_sky
proxy:
  ssl: true
  host: quoterback.borisano.com              # ← unique subdomain
registry:
  server: registry-1.docker.io
  username: borisano
  password:
    - KAMAL_REGISTRY_PASSWORD
env:
  secret:
    - RAILS_MASTER_KEY
    - TELEGRAM_BOT_TOKEN                      # ← the QuoterBack bot's OWN token
    - TELEGRAM_WEBHOOK_SECRET
    - ROLLBAR_ACCESS_TOKEN
    - ADMIN_USERNAME
    - ADMIN_PASSWORD
    - AWS_ACCESS_KEY_ID                       # ← Active Storage S3 (image feature)
    - AWS_SECRET_ACCESS_KEY
    - AWS_REGION
    - AWS_S3_BUCKET
  clear:
    SOLID_QUEUE_IN_PUMA: true
volumes:
  - "quoterback_bot_storage:/rails/storage"  # ← unique volume name
asset_path: /rails/public/assets
builder:
  arch: amd64
  driver: docker
ssh:
  user: ubuntu
aliases:
  console: app exec --interactive --reuse "bin/rails console"
  shell:   app exec --interactive --reuse "bash"
  logs:    app logs -f
```

### 14.3 Pre-requisites & gotchas ⚠️
1. **DNS:** create an A record `quoterback.borisano.com → 52.17.14.111` **before** deploying, or
   Let's Encrypt cert issuance (kamal-proxy auto-cert) will fail.
2. **Distinct everything:** `service`, `image`, `proxy.host`, and `volumes` name **must** differ
   from eye_on_sky's. Reusing the volume name would share/corrupt SQLite data; reusing the
   service name would clobber the other container.
3. **Separate bot token:** QuoterBack needs its **own** Telegram bot (via @BotFather) and token.
   Do not reuse eye_on_sky's token.
4. **`.kamal/secrets`:** follow the same file pattern, but ⚠️ **do not commit raw secrets**.
   eye_on_sky currently has plaintext secrets committed — do **not** replicate that mistake here;
   pull from ENV or a password manager (`kamal secrets fetch`). Keep `config/master.key` out of
   git (it should already be gitignored). Include the AWS S3 keys (image feature) here too.
5. ⚠️ **First-boot DB bootstrap (issue C3):** the `.kamal/hooks/pre-app-boot` hook must run
   **`bin/rails db:prepare`**, NOT `db:migrate`. On a first deploy the volume is empty:
   `db:migrate` does not *create* databases and the hook runs before the app container's own
   `db:prepare` — so a `db:migrate` hook errors on a nonexistent primary DB and aborts the deploy.
   `db:prepare` creates+migrates all four SQLite DBs (primary/cache/queue/cable) idempotently and
   is safe to re-run on every deploy. (Verify `bin/docker-entrypoint` also runs `db:prepare` as a
   backstop.)
6. **Register webhook + command menu after first deploy:** once live, run
   `kamal app exec 'WEBHOOK_URL=https://quoterback.borisano.com/telegram/webhook rails bot:set_webhook'`
   (the secret is already in the container env). Verify with Telegram `getWebhookInfo`. Then run
   `kamal app exec 'rails bot:set_commands'` to register the native ☰ command menu (issue
   UX7/§8.5.1); re-run it whenever the command list changes.
7. **Resource sharing:** two Solid-Queue-in-Puma apps share the box's CPU/RAM. Fine for low
   volume; if load grows, split job processing to a dedicated `job` role (commented example in
   eye_on_sky's deploy.yml).
8. ⚠️ **Do not run `kamal setup` or `kamal proxy reboot` (issue H2):** the kamal-proxy is
   **shared** across all apps on the server; `kamal setup` boots/reconfigures it and can bounce
   the running eye_on_sky bot. On a server where the proxy already exists, deploy this app with
   `kamal deploy` (and `kamal app boot` if needed) — never `kamal setup`.

### 14.4 Deploy sequence
```bash
# once DNS + secrets + BotFather token + S3 bucket are ready:
bin/kamal deploy     # first and subsequent deploys (proxy already exists on server —
                     # do NOT use `kamal setup`, it would reboot the shared proxy — issue H2)
bin/kamal app exec 'WEBHOOK_URL=https://quoterback.borisano.com/telegram/webhook rails bot:set_webhook'
bin/kamal app exec 'rails bot:set_commands'   # register the ☰ command menu (UX7)
```
⚠️ If this is genuinely the very first app on a brand-new server (no proxy yet), `kamal setup` is
required once — but that is **not** the case here (eye_on_sky already established the proxy).

---

## 15. Testing strategy (rspec, mirror eye_on_sky `spec/`)
Minimum coverage the implementation must include:
- **Models:** validations (content length, chat_id uniqueness, timezone validity), per-user
  scoping, tag per-user uniqueness, tagging idempotency, `dependent:` cascade on user/tag delete,
  `quote_deliveries` unique `(user_id, delivery_schedule_id, local_date)` including the
  on-demand-NULL-schedule case that must NOT dedupe (issues N1/N10).
- **UpdateParser:** webhook hash, `ActionController::Parameters`, dev typed object, callback,
  location, **photo (array → largest size)**, document, and **nil/empty update** cases.
- **Dispatcher:** each command; ⚠️ the "text while awaiting_timezone vs while ready" branching;
  confirm-on-text yes/no/expired; **confirm-on-photo**; **pending-quote token isolation (two
  rapid messages don't cross — issue M1)**; **ownership by `from_id` not `chat_id` so a group
  sender isn't rejected (issue N12)**; cross-user callback rejection; `/delete` non-owned id;
  `/quote #tag` (empty tag, valid tag); **`/quote love` with no `love` tag falls back to random,
  not "empty tag" (issue N11)**; tag add/remove idempotent; **tag normalization echoes the stored
  name and reuses the collapsed tag (issue N13)**; **free-tier cap enforced at the single
  creation choke point across /add, confirm-on-text, confirm-on-photo, import (issue N9)**.
- **UX / interaction (§8.5):** confirm-on-text success emits the next-action card with correct
  callbacks (UX4); per-quote `q:del` requires a confirm tap before destroying (UX16); tag-delete
  confirm names the affected schedules **before** deleting (UX16); callback namespace has no
  `q:tag` vs `q:bytag` collision and `answer_callback_query` toasts fire for toggles (UX17/UX25);
  `bot:set_commands` posts the curated menu (UX7); `/cancel` aborts the current flow and does NOT
  delete a schedule (UX23); `/dnd` weekday toggler and delivery `😴 Snooze today` reach the §9.5
  logic (UX22).
- **QuoteScheduler:** `next_run_time` today-vs-tomorrow, across DST, and **DST-gap: the imaginary
  local time is accepted as Rails' auto-resolved instant with NO extra hour-bump (issue N3)**;
  `pending_job_id` persisted in the same transaction as enqueue (issue N5); lookup scoped to
  `finished_at: nil` so a retry's finished row isn't mistaken for the live job (issue N4); cancel
  then enqueue leaves exactly one live pending job; **claimed job counts as pending, failed does
  not**.
- **DeliverQuoteJob:** sends + reschedules; **stale-job guard aborts a duplicate (job_id ≠
  schedule.pending_job_id → no send, issue C2/N5)**; **a `retry_on` retry keeps the same job_id and
  still proceeds (guard doesn't swallow retries, issue N4)**; **empty scope skips send but still
  reschedules (issue H3)**; tag-scoped selection; on-demand `/quote` writes a nil-schedule
  delivery row, bumps counters, but does NOT advance the streak (issue N10); 403 → deactivate, no
  reschedule; transient error retry then reschedule-on-exhaustion; no double-send on post-send
  failure; **image quote → send_photo, long caption → photo + follow-up text (1024 limit)**;
  **`file_id`-invalid → blob.download multipart re-upload, then text-only fallback (issue N6)**.
- **ScheduleQuotesJob:** schedules only enabled schedules with no pending job; ignores failed
  jobs; treats claimed jobs as pending (no duplicate); does not O(N²) scan the jobs table.
- **Rescheduling triggers (issue H1):** changing `/settimezone` reschedules all schedules;
  editing a schedule's time reschedules; disabling cancels the pending job.
- **Image feature:** `AttachQuoteImageJob` downloads + attaches; download failure leaves
  `photo_file_id` usable; bot-token URL never logged; delivery fallback when `file_id` invalid.
- **Import:** oversized file rejected; bad-encoding line handled; free-tier cap honored.
- **Webhook controller:** secret verification valid/invalid/blank; **always returns 200 even when
  the dispatcher raises** (no Telegram retry storm); **boot check: raises when secret blank at
  runtime but does NOT raise during precompile when `SECRET_KEY_BASE_DUMMY` is set (issue N2)**.
- **`editMessageText`:** "message is not modified" error is swallowed on pagination.
- **Admin:** auth required (blank creds → forbidden); stats query numbers.
- Use **webmock** to stub all Telegram HTTP calls (`send_message`, `send_photo`, `getFile`, file
  download, `set_webhook`) and **S3**; **VCR** only if you record real fixtures.
  ⚠️ No test may hit the real Telegram API, real S3, or the network.

---

## 16. Build order (suggested for implementing agents)
1. Rails app skeleton + Gemfile (incl. `aws-sdk-s3`) + multi-db + Solid stack + rspec (green empty
   suite). Configure WAL/busy_timeout + storage.yml services. ⚠️ **Run `bin/rails
   active_storage:install` and migrate (issue N7)** — without this the `active_storage_blobs` /
   `active_storage_attachments` / `active_storage_variant_records` tables never exist and
   `quote.image.attach` raises at runtime. In this multi-DB setup the install migration must land
   in the **primary** DB (the one that holds `quotes`), so it can join; keep it out of the
   queue/cache/cable DBs. Do this in step 1 even though images arrive in step 11, so the schema is
   ready and migrations stay ordered.
2. `TelegramClient` + `UpdateParser` (incl. photo/document) + `Poller` + webhook controller
   (echo bot; verify dev poll; controller always returns 200).
3. `User` model + onboarding state machine + tap-driven `/start` (UX1) + timezone picker
   (button grid + typed fallback) + `set_commands` menu registration (UX7) (+ reschedule hook
   stub).
4. `Quote` model + `QuoteCreator` choke point (N9) + `/add` + confirm-on-text (token-keyed) with
   success-card next actions (UX4) + `/quote` + button-driven `/list` + per-quote action row +
   `q:show` detail card (UX9/UX11) + `/delete` with confirm (UX16).
5. `delivery_schedules` + `QuoteScheduler` (pending_job_id) + `DeliverQuoteJob` (stale-job guard,
   empty-scope reschedule, delivery action row UX15) + `ScheduleQuotesJob` + button-first
   `/schedule` builder + `/schedules` manager (UX13/14) + recurring.yml (prod+dev). This is the
   scheduling core — get its tests green before layering tags on top. (`/cancel` = abort-flow
   only, UX23.)
6. Import from file.
7. `/settings` control panel (UX21) wiring the above managers together.
8. Admin dashboard + StatsQuery.
9. Deploy config (Dockerfile, deploy.yml, `db:prepare` hook, secrets incl. AWS) + first deploy
   via `kamal deploy` + webhook + `bot:set_commands` registration.
10. **Tags feature:** `tags`/`taggings` + button tag picker/toggle (UX9) + `/tags` + `/quote #tag`
    (`q:bytag`) + tag-filtered `/list`.
11. **Per-tag schedules:** `delivery_schedules.tag_id` UX (builder tag step, `/schedules`
    manager) — engine already supports it from step 5.
12. **Image attachments:** `photo_file_id` + Active Storage + confirm-on-photo + `q:img`/`/addimage`
    + `AttachQuoteImageJob` + `send_photo` delivery with caption/fallback handling.
13. Remaining V2: favourites/weighting (toggle) → streaks → DND (`/dnd` toggler + snooze, UX22) →
    stats → free-tier stub.
14. Harden: Rollbar, brakeman, bundler-audit, rubocop all clean.

Each step ends with green rspec + a manual smoke test against a dev bot token.

---

## 17. Security & privacy checklist (must pass before ship)
- [ ] Every quote/tag/schedule query scoped to the current user — no cross-user access.
- [ ] Callback data ownership verified (cached entry's `from_id` matches the sender's `from.id`).
- [ ] Confirm-on-text/photo keyed by random token, not chat_id (no cross-message bleed).
- [ ] Webhook secret token verified in production **and boot fails if it's unset** (§13).
- [ ] User quote content HTML-escaped **or** sent as plain text (decided & tested).
- [ ] Bot token never logged (esp. in `getFile` download URLs and error messages).
- [ ] Secrets (incl. AWS S3 keys) pulled from ENV/password manager, never committed.
- [ ] `force_ssl` / `assume_ssl` on in production.
- [ ] 403 handling deactivates the user; no infinite retries.
- [ ] Controller always returns 200 to Telegram (no retry storms).
- [ ] Deploy uses `kamal deploy`, not `kamal setup` (shared proxy untouched).
- [ ] Scheduling: stale-job guard prevents double-send; no O(N²) job-table scans.

---

## 18. Future feature (post-V2): Public sharing, voting & discovery — forward-compatibility

**Verdict: compatible with the current architecture.** Nothing in the plan blocks this; every
change is **additive** (new columns/tables/read-paths). Implement it **last**, after V2. This
section exists so earlier phases don't make a choice that would interfere.

### 18.1 Why current choices don't interfere
- **Per-user scoping boundary (§4/§6):** discovery reads *other* users' quotes, but via a
  **separate, explicit public scope** (`Quote.public_visible`), not a weakening of ownership.
  Private quotes stay strictly scoped; only `visibility: :public` rows are ever exposed. Keep the
  ownership rule for all writes/deletes/edits and for reading private quotes.
- **Ownership model (`quotes.user_id`):** "add someone else's quote to mine" = **fork/copy** (a
  new row I own with `forked_from_id`), not shared ownership — fully consistent with the scoping
  model.
- **Image attachments (§6.6):** forking copies `photo_file_id` (bot-global, re-sendable by any
  chat) and optionally re-attaches the Active Storage blob. Unchanged.
- **`/delete` scoped resolution (§6.1):** already uses `user.quotes.find_by`; forks/votes on
  other rows are unaffected.
- **Admin dashboard (§10):** ready home for moderation/reporting.
- **Recurring jobs (§7.5):** ready home for counter-reconciliation / leaderboard jobs.

### 18.2 Conventions to reserve NOW (cheap insurance, honor during earlier phases)
1. **No raw sequential PKs in anything user-shareable.** Internal `/list`/`/delete` by PK is fine
   (scoped), but share links + the discovery page need a **non-enumerable `public_id`**
   (UUID/ULID) on quotes. Add the column whenever; just never build a share link on the integer PK.
2. **`/start` parses an optional payload** (§11) — reserved above.
3. **Never expose `telegram_chat_id` as public identity.** Public attribution uses an opt-in
   `public_handle` on `users`; show the handle (or "Anonymous"), never the chat id.
4. **Reserve a `🌍 Make public` slot in the `q:show` detail card action row (issue UX26).** Keep a
   stable position for it (callback `q:pub:<id>`, fits the 64-byte budget) so adding sharing later
   doesn't reshuffle the layout users have learned.
5. **`/start q_<public_id>` deep link → friendly "coming soon", not silent ignore (issue UX26).**
   From day one route unknown/not-yet-built `/start` payloads to "Shared quotes are coming soon!"
   so any early-leaked share link doesn't look broken (refines the §11 payload reservation).
6. **Build `/discover` on the §8.5.4 paginate-and-edit + detail-card pattern (issue UX27)** —
   callbacks `disc:pg:<n>:<period>`, `vote:up:<public_id>`, `vote:dn:<public_id>`,
   `fork:<public_id>`, `report:<public_id>` (§8 namespace). No new interaction pattern for users
   or implementers to learn.

### 18.3 Data model (added when built)
- `quotes` += `visibility` (`private` default / `public`), `public_id` (uuid, unique),
  `forked_from_id` (self-ref FK, nullable, `on_delete: :nullify`), cached `upvotes_count`,
  `downvotes_count`, `score`.
- `quote_votes`: `user_id`, `quote_id`, `value` (+1/−1), timestamps; **unique `(user_id,
  quote_id)`** (one vote per user per quote; re-voting updates the row). Recommend disallowing
  self-votes.
- `users` += `public_handle` (opt-in, unique, nullable), `discoverable` (bool).
- Votes always accrue on the **original** public row (its `user_id` = the poster), so poster
  totals are `user.quotes.public_visible.sum(:upvotes_count)`, etc. Forks carry `forked_from_id`
  for attribution ("via @handle").

### 18.4 Behaviour
- **Publish:** `/publish <id>` or inline "🌍 Make public" toggle → `visibility: :public` (opt-in,
  reversible; going private keeps existing votes but hides from discovery).
- **Discover — two options:**
  - **In-bot (recommended, lowest friction):** `/discover` paginates public quotes with inline
    `👍 / 👎` + "➕ Add to my quotes" + "🚩 Report". Voter identity comes free from the update —
    **no web auth needed.**
  - **Web page** (`/discover`, `/q/<public_id>`): needs user identification to vote → **Telegram
    Login Widget** or per-user deep-link tokens. ⚠️ This is the *only* part needing new auth
    infra; the in-bot path avoids it. Do in-bot first.
- **Vote:** upsert into `quote_votes`; update cached counters (transaction or counter job).
  Idempotent per user.
- **Best quotes:** leaderboard ordered by `score`. ⚠️ Use a **Wilson lower-bound** or HN-style
  time-decay, not raw `up − down`, so a 5:0 quote doesn't outrank 500:50 and old quotes don't
  dominate forever. Offer "Top today / week / all time".
- **Fork ("add to my quotes"):** `current_user.quotes.create!(content:, author:, source:,
  photo_file_id:, forked_from_id: original.id, visibility: :private)`. ⚠️ Counts against the
  free-tier quote limit (§9.7).
- **Poster stats:** `/mypublic` lists the user's public quotes with vote tallies and fork counts.

### 18.5 Edge cases ⚠️
- **Deleting a public quote with votes/forks:** prefer **soft-delete / tombstone** (retain for
  leaderboard + attribution, mark removed) over hard delete. Forks are independent rows and
  survive; `forked_from_id` nullifies on hard delete.
- **Moderation:** inline "🚩 Report" → admin queue (§10); reported/removed quotes hidden from
  discovery. Public sharing is opt-in and reversible (GDPR-friendly); expose only the opt-in handle.
- **Vote gaming:** unique `(user_id, quote_id)` blocks per-account stuffing; ignore self-votes;
  consider rate-limiting.
- **Counter drift:** cached `score`/counts can drift under races — reconcile with a periodic
  recount job (fits §7.5).
- **Duplicate forks:** optionally prevent forking the same original twice (check `forked_from_id`
  within `user.quotes`).

### 18.6 Bottom line
No current migration, model, or scheduling decision must change now. Build §18 after V2; honor
only the three reservations in §18.2 in the meantime.
