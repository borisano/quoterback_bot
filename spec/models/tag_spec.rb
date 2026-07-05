require "rails_helper"

RSpec.describe Tag, type: :model do
  describe "validations" do
    it { is_expected.to validate_presence_of(:name) }
    it { is_expected.to validate_length_of(:name).is_at_most(30) }
    it { is_expected.to belong_to(:user) }
  end

  describe "name normalization" do
    it "strips leading #" do
      tag = create(:tag, name: "#stoic")
      expect(tag.name).to eq("stoic")
    end

    it "downcases the name" do
      tag = create(:tag, name: "MOTIVATION")
      expect(tag.name).to eq("motivation")
    end

    it "strips whitespace" do
      tag = create(:tag, name: "  fun  ")
      expect(tag.name).to eq("fun")
    end
  end
end
