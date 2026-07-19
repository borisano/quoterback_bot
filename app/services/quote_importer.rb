require "set"

# Bulk-creates quotes from the raw contents of an uploaded text file (plan §6.4).
# One quote per non-blank line. Routes every line through QuoteCreator so the same
# validation (and, later, the free-tier limit) applies as for a single /add. Skips
# lines that are too short/invalid or that duplicate an existing (or already-seen)
# quote, and reports how many landed vs how many were skipped.
class QuoteImporter
  MAX_BYTES = 256 * 1024 # 256 KB cap (plan §6.4)
  MAX_LINES = 500        # per-import line cap (plan §6.4)

  Result = Struct.new(:imported, :skipped, :error_message, keyword_init: true) do
    def success?
      error_message.nil?
    end

    def failure?
      !success?
    end
  end

  def self.call(user:, content:)
    new(user: user, content: content).call
  end

  def initialize(user:, content:)
    @user = user
    @content = content.to_s
  end

  def call
    if @content.bytesize > MAX_BYTES
      return failure("That file is too large — imports are capped at 256 KB.")
    end

    lines = parse_lines(@content)
    return failure("I couldn't find any quotes in that file — one quote per line, please.") if lines.empty?

    if lines.size > MAX_LINES
      return failure("That's #{lines.size} lines — imports are capped at #{MAX_LINES} quotes at a time.")
    end

    import(lines)
  end

  private

  def parse_lines(content)
    content
      .encode("UTF-8", invalid: :replace, undef: :replace)
      .split(/\r?\n/)
      .map(&:strip)
      .reject(&:blank?)
  end

  def import(lines)
    existing = @user.quotes.pluck(:content).to_set
    imported = 0
    skipped = 0

    lines.each do |line|
      if existing.include?(line)
        skipped += 1
        next
      end

      result = QuoteCreator.call(user: @user, content: line)
      if result.success?
        imported += 1
        existing << line # guard against later duplicates in the same file
      else
        skipped += 1
      end
    end

    Result.new(imported: imported, skipped: skipped, error_message: nil)
  end

  def failure(message)
    Result.new(imported: 0, skipped: 0, error_message: message)
  end
end
