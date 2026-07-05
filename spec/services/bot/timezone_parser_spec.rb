require "rails_helper"

RSpec.describe Bot::TimezoneParser do
  describe ".parse" do
    it "returns an ActiveSupport::TimeZone for an exact IANA name" do
      result = described_class.parse("Europe/London")
      expect(result).to be_a(ActiveSupport::TimeZone)
      expect(result.name).to eq("London")
    end

    it "returns a timezone for a city name (case-insensitive)" do
      result = described_class.parse("london")
      expect(result).not_to be_nil
    end

    it "parses a positive UTC offset like +9" do
      result = described_class.parse("+9")
      expect(result).not_to be_nil
    end

    it "parses a negative UTC offset like -5" do
      result = described_class.parse("-5")
      expect(result).not_to be_nil
    end

    it "parses UTC+9 format" do
      result = described_class.parse("UTC+9")
      expect(result).not_to be_nil
    end

    it "returns nil for a completely invalid input" do
      result = described_class.parse("notazone")
      expect(result).to be_nil
    end
  end
end
