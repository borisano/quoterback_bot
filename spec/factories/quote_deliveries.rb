FactoryBot.define do
  factory :quote_delivery do
    association :user
    association :quote
    local_date { Date.current }
    context { "on_demand" }
    delivered_at { Time.current }
  end
end
