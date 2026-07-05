# quote_bot — Personal Quote Collection & Daily Delivery Bot
### July 2026

---

## The Core Idea

Users upload their own favourite quotes — from books, films, people they admire, things they wrote themselves — and the bot delivers them back on a schedule or on demand. The key differentiator vs. every other quote bot: **it's YOUR quotes, not someone else's curated list.**

---

## Competition Analysis

Existing bots fall into two categories — neither fully covers this idea:

### Generic Quote Bots (saturated, not your competition)
| Bot | What it does | Gap |
|---|---|---|
| `@MotivationalQuotes_Bot` | Sends random quotes from public database | Not personal — anyone gets same quotes |
| `@motivational_quote_bot` | On-demand quote from public API | Same issue |
| `QuoteSparkBot` | Multilingual quotes + image generation, schedule to channels | Closest competitor — but still curated library, not user's own collection |
| GitHub OSS bots | Basic send-quote-from-file | No UX, developer-only |

### Web apps (different surface, indirect competition)
- **Readwise** — stores highlights from books/articles, sends daily review. Very close concept but focused on book highlights, requires subscription ($7.99/mo), web-first. No Telegram.
- **Instapaper / Kindle highlights** — saves quotes but no delivery/scheduling.
- **Day One (journal app)** — has "on this day" feature but not quote-focused.

**Verdict:** The personal upload + Telegram delivery angle has **no strong direct competitor** in the Telegram ecosystem. Readwise is the closest product overall but lives on a different platform with a different audience.

---

## Feature Set

### MVP Features
- `/add` — add a quote (text, optional author/source tag)
- **Confirm-on-text** — send any plain message → bot offers inline "✅ Add as quote / ❌ No" (frictionless capture; ported from prior prototype)
- `/quote` (alias `/random`) — get a random quote from your collection right now
- Inline button: **"Give me a quote"** on bot home screen
- `/schedule` — set daily delivery time (e.g. "09:00 every day")
- `/settimezone` + `/timezones` — set timezone (city name, full name, or UTC offset) and browse common zones
- `/settings` — dashboard: quote count, timezone, current local time, active schedule
- `/cancel` — turn off daily delivery
- `/list` (alias `/quotes`) — see all your quotes (paginated)
- `/delete [id]` — remove a quote
- Import from text file (one quote per line)

> **Note:** The prior prototype (`quoterback_bot_old`) shipped confirm-on-text capture, `/settings`, dedicated timezone commands, and timezone-aware per-minute delivery, but had **no delete** and **no pagination**. Those two gaps are fixed above; tags, favourites, and import are net-new.

### V2 Features
- **Categories/tags** — tag quotes by mood (`#motivation`, `#stoic`, `#funny`, `#love`) and request by tag: "Give me a stoic quote"
- **Quote streaks** — gamification: "You've received 30 quotes in a row! 🔥"
- **Favourite/unfavourite** — mark quotes you loved getting, bot learns to send them more often
- **Do Not Disturb** — no delivery on weekends, or custom days
- **Multiple schedules** — morning + evening delivery
- **Quote stats** — "You have 47 quotes from 12 authors. Most common tag: #stoic"

### V3 / AI-Enhanced Features
- **AI image generation** — wrap quote in a beautiful card image (Stable Diffusion / DALL-E background, styled text overlay) → shareable to Instagram Stories, WhatsApp Status
- **Mood-based delivery** — user sends a mood emoji, bot picks a contextually fitting quote from their collection
- **AI quote suggestions** — "Based on your collection, you might like this quote by Marcus Aurelius…"
- **AI-generated quotes** — bot can *write* a new quote in the style of authors already in your collection (opt-in, clearly labelled as AI-generated)
- **Public quote page** — opt-in shareable link: `quotebo.t/yourname` showing your favourite quotes as a public profile

### Social Features
- **Share a quote** — one tap sends a quote as a Telegram message to any chat
- **Quote of the Day channel** — your personal QOTD channel, bot auto-posts daily (great for followers/friends)
- **Shared collections** — invite friends to contribute to a joint collection (e.g., "Our team's favourite quotes")
- **Quote battle** — bot sends two quotes from your collection, you pick the better one (pairs naturally with `sorting_bot` concept!)

---

## Tech Stack

```ruby
# Gemfile
gem 'telegram-bot'     # Bot interaction
gem 'sidekiq'          # Scheduled delivery (cron-style per user timezone)
gem 'sidekiq-cron'     # Dynamic per-user cron jobs
gem 'pg'               # Quotes DB (users, quotes, tags, delivery_schedule)
gem 'redis'            # Session state
gem 'ruby-openai'      # AI features (optional V3)
```

**DB schema (simplified):**
```
users: telegram_id, timezone, schedule_time, streak_count
quotes: id, user_id, text, author, source, tags[], favourited, times_delivered
deliveries: user_id, quote_id, delivered_at
```

**Scheduling challenge:** Each user has their own delivery time + timezone. Sidekiq-cron can handle this with one job per user stored in Redis, or a single global job that queries "who should receive a quote right now?" every minute.

**Hosting:** Same as other bots — Fly.io + Redis + Postgres, ~$10/mo.

---

## Monetization

| Tier | Limits | Price |
|---|---|---|
| **Free** | 20 quotes max, 1 delivery/day, no image generation | Free |
| **Premium** | Unlimited quotes, multiple schedules, image cards, AI features | 500 Stars/mo (~$6.50 net) |
| **Lifetime** | All premium features forever | 5,000 Stars one-time (~$65 net) |

Additional revenue:
- **Sponsored quotes** — partner with a publisher/author to include opt-in "discovery quotes" from their books (native advertising, user-controlled)
- **Readwise competitor play** — if this grows, target Readwise subscribers who want a simpler/cheaper Telegram-native alternative

---

## Honest Assessment

| Aspect | Score |
|---|---|
| Originality | ⭐⭐⭐ Good — personal upload angle is underserved |
| Competition | ⭐⭐⭐⭐ Low on Telegram; moderate on web |
| Build difficulty | ★★☆☆☆ Easy-Medium |
| Build time (MVP) | 1–2 weeks |
| Monetization | ⭐⭐ Modest — low ARPU, needs volume |
| Viral potential | ⭐⭐ Low — personal tool, not inherently social |
| Passive income fit | ⭐⭐⭐ Good once built — minimal maintenance |

**Bottom line:** A solid side project. Not a business-maker on its own but a great portfolio piece and genuinely useful product. Best as a feature bundled into a broader "personal productivity" bot suite, or as a loss-leader that funnels users to higher-value bots. The image generation + social sharing angle (V3) is where real virality could come from.
