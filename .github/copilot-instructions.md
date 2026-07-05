# QuoterBack Bot — Copilot Agent Instructions

## Commit policy

**Never** add a `Co-authored-by: Copilot` trailer (or any Copilot co-authorship trailer) to any commit in this repository. Commits are authored solely by the human developer.

## Development workflow — TDD mandatory

All features **must** be implemented Test-Driven:

1. Write a failing test (RSpec) that describes the expected behaviour.
2. Run it and confirm it is red.
3. Write the minimum production code to make it green.
4. Refactor if needed (stay green).
5. Repeat.

Do **not** write production code before the corresponding failing spec exists, unless the task explicitly says otherwise.

## Tech stack (fixed — do not deviate)

- Ruby on Rails 8.1.x, Ruby 3.4.3
- SQLite (multi-db: primary, cache, queue, cable)
- Solid Queue (in-Puma), Solid Cache, Solid Cable
- telegram-bot-ruby (webhook in prod, long-polling in dev)
- RSpec + FactoryBot + WebMock + VCR + Shoulda-Matchers
- RuboCop (rubocop-rails-omakase), Brakeman, Bundler-Audit
- Kamal 2 for deployment

## Reference implementation

Mirror the architecture and conventions of `~/projects/eye_on_sky_bot` (same author, same
tech stack, production-proven). Where the implementation plan says "as in eye_on_sky", open
that project and copy the *pattern*.

**Do NOT copy from** `~/projects/quoterback_bot_old` — discarded prototype, wrong patterns.

## Architecture — service-object layering

Keep controllers thin. All business logic lives in service objects under `app/services/bot/`.
See `docs/implementation_plan.md` for the full layered diagram.
