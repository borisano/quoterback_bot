FactoryBot.define do
  factory :tag do
    association :user
    sequence(:name) { |n| "tag#{n}" }
  end
end
