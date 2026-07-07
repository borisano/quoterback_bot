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

    context "with a tag filter" do
      let!(:tag) { create(:tag, user: user, name: "stoic") }
      let!(:in_scope) { create(:quote, user: user) }
      let!(:out_scope) { create(:quote, user: user) }
      before { in_scope.taggings.create!(tag: tag) }

      it "returns only quotes carrying that tag" do
        expect(described_class.random_for(user, tag: tag)).to eq(in_scope)
      end

      it "returns nil when the tag has no quotes" do
        in_scope.taggings.destroy_all
        expect(described_class.random_for(user, tag: tag)).to be_nil
      end
    end
  end

  describe ".weighted_sample (favourite weighting)" do
    let(:user) { create(:user) }

    it "gives favourited quotes FAVOURITE_WEIGHT entries and others 1" do
      fav = create(:quote, user: user, favourited: true)
      plain = create(:quote, user: user, favourited: false)
      pool = described_class.weighted_pool([ fav, plain ])
      expect(pool.count(fav)).to eq(Quote::FAVOURITE_WEIGHT)
      expect(pool.count(plain)).to eq(1)
    end

    it "returns nil for an empty candidate list" do
      expect(described_class.weighted_sample([])).to be_nil
    end

    it "applies weighting through random_for (favourite dominates a large pool)" do
      create(:quote, user: user, favourited: true, content: "Favourite quote here.")
      create_list(:quote, 3, user: user, favourited: false)
      picks = Array.new(200) { described_class.random_for(user).content }
      expect(picks.count("Favourite quote here.")).to be > (200 / 4)
    end
  end
end
