require "rails_helper"

RSpec.describe User, type: :model do
  describe "validations" do
    subject { create(:user) }

    it { is_expected.to validate_presence_of(:telegram_chat_id) }
    it { is_expected.to validate_uniqueness_of(:telegram_chat_id) }
  end

  describe "associations" do
    it { is_expected.to have_many(:quotes).dependent(:destroy) }
    it { is_expected.to have_many(:tags).dependent(:destroy) }
    it { is_expected.to have_many(:delivery_schedules).dependent(:destroy) }
    it { is_expected.to have_many(:quote_deliveries).dependent(:destroy) }
  end

  describe ".find_or_create_from_update!" do
    let(:update) do
      Bot::UpdateParser::ParsedUpdate.new(
        chat_id: 999_111,
        from_id: 999_111,
        first_name: "Bob",
        language_code: "en",
        text: "/start",
        callback_data: nil,
        callback_query_id: nil,
        message_id: nil
      )
    end

    it "creates a new user on first call" do
      expect { described_class.find_or_create_from_update!(update) }
        .to change(User, :count).by(1)
    end

    it "returns the same user on subsequent calls" do
      user1 = described_class.find_or_create_from_update!(update)
      user2 = described_class.find_or_create_from_update!(update)
      expect(user1.id).to eq(user2.id)
    end

    it "sets first_name from the update" do
      user = described_class.find_or_create_from_update!(update)
      expect(user.first_name).to eq("Bob")
    end

    it "touches last_interaction_at" do
      user = described_class.find_or_create_from_update!(update)
      expect(user.last_interaction_at).to be_within(5.seconds).of(Time.current)
    end
  end

  describe "#configured?" do
    it "returns false when timezone is nil" do
      expect(build(:user, timezone: nil).configured?).to be false
    end

    it "returns true when timezone is set" do
      expect(build(:user, :with_timezone).configured?).to be true
    end
  end

  describe "STATES constant" do
    it "includes awaiting_tag_name" do
      expect(User::STATES).to include("awaiting_tag_name")
    end
  end

  describe "state validation" do
    it "allows nil state" do
      user = build(:user, state: nil)
      expect(user).to be_valid
    end

    it "rejects invalid state" do
      user = build(:user, state: "invalid_state")
      expect(user).not_to be_valid
    end

    it "accepts valid state" do
      user = build(:user, state: "awaiting_tag_name")
      expect(user).to be_valid
    end
  end
end
