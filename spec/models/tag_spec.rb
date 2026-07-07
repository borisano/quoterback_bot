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

    it "strips multiple leading #" do
      tag = create(:tag, name: "##stoic")
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

    it "collapses internal whitespace to underscores (M8)" do
      tag = create(:tag, name: "#My Tag Name")
      expect(tag.name).to eq("my_tag_name")
    end
  end

  describe ".normalize (M8 — single source of truth)" do
    it "strips #, downcases, trims, and underscores whitespace" do
      expect(described_class.normalize("#  My Tag ")).to eq("my_tag")
    end

    it "returns an empty string for nil" do
      expect(described_class.normalize(nil)).to eq("")
    end
  end

  describe "format validation (M8)" do
    it "rejects names with characters outside [a-z0-9_]" do
      tag = build(:tag, name: "bad!name")
      expect(tag).not_to be_valid
      expect(tag.errors[:name]).to be_present
    end

    it "accepts a normalized name" do
      expect(build(:tag, name: "good_name_1")).to be_valid
    end
  end
end
