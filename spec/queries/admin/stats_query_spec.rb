require "rails_helper"

RSpec.describe Admin::StatsQuery do
  describe "#call" do
    let!(:user) { create(:user, :with_timezone) }
    let!(:quote) { create(:quote, user: user, author: "Marcus Aurelius") }

    it "returns user counts" do
      result = described_class.new.call
      expect(result[:users_total]).to eq(1)
      expect(result[:users_active]).to eq(1)
    end

    it "returns quote count" do
      result = described_class.new.call
      expect(result[:quotes_total]).to eq(1)
    end

    it "includes top authors" do
      result = described_class.new.call
      expect(result[:top_authors]).to include("Marcus Aurelius" => 1)
    end
  end
end
