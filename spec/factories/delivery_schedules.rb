FactoryBot.define do
  factory :delivery_schedule do
    association :user, :with_timezone
    hour { 9 }
    minute { 0 }
    enabled { true }
  end
end
