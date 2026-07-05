FactoryBot.define do
  factory :quote do
    association :user
    content { "The only way to do great work is to love what you do." }
    author { "Steve Jobs" }

    trait :with_author do
      author { "Some Author" }
    end

    trait :favourited do
      favourited { true }
    end
  end
end
