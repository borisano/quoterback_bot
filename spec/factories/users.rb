FactoryBot.define do
  factory :user do
    sequence(:telegram_chat_id) { |n| 100_000 + n }
    first_name { "Alice" }
    telegram_language_code { "en" }
    active { true }

    trait :with_timezone do
      timezone { "Europe/London" }
    end

    trait :inactive do
      active { false }
    end
  end
end
