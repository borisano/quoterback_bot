require "rails_helper"

RSpec.describe Quote, type: :model do
  describe "validations" do
    it { is_expected.to validate_presence_of(:content) }
    it { is_expected.to validate_length_of(:content).is_at_least(3).is_at_most(1000) }
    it { is_expected.to validate_length_of(:author).is_at_most(100) }
    it { is_expected.to validate_length_of(:source).is_at_most(200) }
    it { is_expected.to belong_to(:user) }
    it { is_expected.to have_many(:taggings).dependent(:destroy) }
    it { is_expected.to have_many(:tags).through(:taggings) }
  end

  describe ".random_for" do
    let(:user) { create(:user) }

    it "returns a quote from the user's collection" do
      quote = create(:quote, user: user)
      expect(described_class.random_for(user)).to eq(quote)
    end

    it "returns nil when the user has no quotes" do
      expect(described_class.random_for(user)).to be_nil
    end

    it "never returns another user's quote" do
      other_user = create(:user)
      create(:quote, user: other_user)
      expect(described_class.random_for(user)).to be_nil
    end
  end
end
