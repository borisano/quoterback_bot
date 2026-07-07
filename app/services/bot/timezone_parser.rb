module Bot
  module TimezoneParser
    # Keyed by float hours so half/quarter-hour offsets resolve (M2).
    OFFSET_TO_ZONE = {
      -12   => "International Date Line West",
      -11   => "American Samoa",
      -10   => "Hawaii",
      -9    => "Alaska",
      -8    => "Pacific Time (US & Canada)",
      -7    => "Mountain Time (US & Canada)",
      -6    => "Central Time (US & Canada)",
      -5    => "Eastern Time (US & Canada)",
      -4    => "Atlantic Time (Canada)",
      -3    => "Buenos Aires",
      -2    => "Mid-Atlantic",
      -1    => "Azores",
       0    => "London",
       1    => "Paris",
       2    => "Athens",
       3    => "Moscow",
       3.5  => "Tehran",
       4    => "Abu Dhabi",
       4.5  => "Kabul",
       5    => "Islamabad",
       5.5  => "Chennai",
       5.75 => "Kathmandu",
       6    => "Dhaka",
       7    => "Bangkok",
       8    => "Beijing",
       9    => "Tokyo",
       9.5  => "Darwin",
      10    => "Sydney",
      11    => "Magadan",
      12    => "Auckland",
      13    => "Nuku'alofa"
    }.freeze

    # Common cities Rails does not expose as a friendly TimeZone name (M2).
    CITY_ALIASES = {
      "new york"      => "Eastern Time (US & Canada)",
      "nyc"           => "Eastern Time (US & Canada)",
      "toronto"       => "Eastern Time (US & Canada)",
      "chicago"       => "Central Time (US & Canada)",
      "los angeles"   => "Pacific Time (US & Canada)",
      "san francisco" => "Pacific Time (US & Canada)",
      "seattle"       => "Pacific Time (US & Canada)"
    }.freeze

    module_function

    def parse(input)
      return nil if input.blank?

      input = input.strip

      # 1. Exact IANA match via ActiveSupport — normalize to Rails-named zone
      tz = ActiveSupport::TimeZone[input]
      if tz
        # Rails 8 may return a raw IANA-named zone; normalize to a display-named zone
        return normalize_iana_zone(tz)
      end

      # 2. City/country name match (case-insensitive)
      tz = ActiveSupport::TimeZone.all.find { |z| z.name.downcase == input.downcase }
      return tz if tz

      # 2b. Common-city alias for zones Rails doesn't name (M2)
      if (alias_name = CITY_ALIASES[input.downcase])
        return ActiveSupport::TimeZone[alias_name]
      end

      # 3. UTC offset like +9, -5, UTC+9, UTC-5, +09:00, +5:30, +5:45
      offset_match = input.match(/\A(?:UTC)?([+-]\d{1,2})(?::(\d{2}))?\z/i)
      if offset_match
        hours = offset_match[1].to_i
        minutes = offset_match[2].to_i
        fractional = hours + (offset_match[1].start_with?("-") ? -1 : 1) * (minutes / 60.0)
        zone_name = OFFSET_TO_ZONE[fractional] || OFFSET_TO_ZONE[hours]
        return ActiveSupport::TimeZone[zone_name] if zone_name
      end

      nil
    end

    def common_zones
      %w[
        London
        Paris
        Moscow
        Abu\ Dhabi
        Bangkok
        Tokyo
        Sydney
      ].filter_map { |name| ActiveSupport::TimeZone[name] } +
        [ ActiveSupport::TimeZone["Eastern Time (US & Canada)"] ].compact
    end

    # Converts a raw IANA-named zone (e.g. name="Europe/London") to the Rails
    # display-named equivalent (e.g. name="London"), preferring the zone whose
    # display name matches the last segment of the IANA name.
    def normalize_iana_zone(tz)
      return tz unless tz.name.include?("/")

      iana_name = tz.tzinfo.name
      candidates = ActiveSupport::TimeZone.all.select { |z| z.tzinfo.name == iana_name }
      return tz if candidates.empty?

      last_segment = iana_name.split("/").last.tr("_", " ")
      candidates.find { |z| z.name.casecmp?(last_segment) } || candidates.first
    end
  end
end
