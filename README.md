# QuoterBack Bot

A Telegram bot that lets users build their **own** personal quote collection and delivers quotes back on a schedule or on demand. Unlike every other quote bot — it's **your** quotes, not someone else's curated list.

---

## Product Vision

Users add favourite quotes from books, films, people they admire, or things they wrote themselves. The bot:
- Delivers a quote at a set time every day (configurable, timezone-aware)
- Gives a quote on demand via a button or `/quote` command
- Lets users organise, tag, and browse their collection

Full research and competitor analysis: [`docs/product_research.md`](docs/product_research.md)

---

## MVP Features

- `/add` — add a quote (text + optional author/source)
- **Confirm-on-text** — send any plain message and the bot asks "Add this as a quote?" with inline ✅/❌ buttons (no command needed)
- `/quote` (alias `/random`) — get a random quote from your collection right now
- `/list` (alias `/quotes`) — browse all quotes (paginated)
- `/delete [id]` — remove a quote
- `/settings` — dashboard: quote count, timezone, current local time, active schedules
- `/schedule` — set up a daily delivery: a button-first builder (pick a tag or the whole
  collection → hour → minutes), or `/schedule 09:00` as a typed shortcut
- `/schedules` — manage every daily delivery: edit, pause/resume, or delete each one
- `/cancel` — abort whatever flow you're in the middle of (to stop a delivery, use `/schedules`)
- `/settimezone` — set your timezone (accepts city names, full names, or UTC offsets like `+9`)
- `/timezones` — list common timezones with their current times
- Inline "Give me a quote" button on bot home screen
- Import quotes from a text file (one per line)

## Planned V2 Features

- Tags/categories (`#stoic`, `#funny`, `#motivation`) — ✅ shipped (tag picker, `/quote #tag`)
- Favourite quotes + weighted delivery — ✅ shipped
- Multiple daily schedules (incl. per-tag schedules) — ✅ shipped (`/schedules`)
- Quote streaks 🔥 (collected; `/stats` surfacing planned)
- Do Not Disturb days

## Planned V3 / AI Features

- AI-generated quote cards (image with styled text) → shareable to Stories
- Mood-based quote selection
- AI quote suggestions based on collection
- Public shareable quote page (`quoterback.bot/yourname`)

---

## Tech Stack

- **Ruby on Rails 8** + SQLite (or Postgres in prod)
- **telegram-bot-ruby** — Telegram Bot API
- **SolidQueue** — background jobs for scheduled delivery
- **SolidCache** — session/state caching

---

## Setup

```bash
bundle install
cp .env.example .env   # add TELEGRAM_BOT_TOKEN
rails db:create db:migrate db:seed
rails server
```

---

## Monetization Plan

| Tier | Limits | Price |
|---|---|---|
| Free | 20 quotes, 1 delivery/day | Free |
| Premium | Unlimited quotes, multiple schedules, image cards, AI | ~$6.50/mo (500 Stars) |
| Lifetime | All premium forever | ~$65 (5,000 Stars) |

---

## Running Tests

```bash
bundle exec rspec
```
