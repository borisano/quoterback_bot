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

    context "half/quarter-hour offsets (M2)" do
      it "parses +5:30 (India) to a +05:30 zone" do
        result = described_class.parse("+5:30")
        expect(result).not_to be_nil
        expect(result.formatted_offset).to eq("+05:30")
      end

      it "parses UTC+5:30" do
        result = described_class.parse("UTC+5:30")
        expect(result&.formatted_offset).to eq("+05:30")
      end

      it "parses +5:45 (Nepal)" do
        expect(described_class.parse("+5:45")&.formatted_offset).to eq("+05:45")
      end

      it "parses +9:30 (Australia Central)" do
        expect(described_class.parse("+9:30")&.formatted_offset).to eq("+09:30")
      end

      it "parses +3:30 (Iran)" do
        expect(described_class.parse("+3:30")&.formatted_offset).to eq("+03:30")
      end

      it "parses +13 (Tonga)" do
        expect(described_class.parse("+13")&.formatted_offset).to eq("+13:00")
      end

      it "still parses a whole +05:00 offset" do
        expect(described_class.parse("+05:00")&.formatted_offset).to eq("+05:00")
      end
    end

    context "city aliases Rails does not name (M2)" do
      it "resolves 'new york' to US Eastern" do
        expect(described_class.parse("new york")&.formatted_offset).to eq("-05:00")
      end

      it "resolves 'Los Angeles' to US Pacific (case-insensitive)" do
        expect(described_class.parse("Los Angeles")&.formatted_offset).to eq("-08:00")
      end

      it "resolves 'toronto' to US Eastern" do
        expect(described_class.parse("toronto")&.formatted_offset).to eq("-05:00")
      end
    end
  end
end
