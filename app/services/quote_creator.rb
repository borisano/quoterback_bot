# The single choke point through which every quote is born. Centralizing
# creation here keeps validation messaging consistent across all capture paths
# (/add, awaiting_quote_text, confirm-on-text, and — later — import/photo) and
# gives the free-tier limit stub (plan §9.7) one place to live.
class QuoteCreator
  CONTENT_ERROR = "Quotes need to be 3–1000 characters."

  Result = Struct.new(:quote, :error_message) do
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
    @content = content.to_s.strip
  end

  def call
    quote = @user.quotes.new(content: @content)
    if quote.save
      Result.new(quote, nil)
    else
      Result.new(nil, human_error(quote))
    end
  end

  private

  def human_error(quote)
    if quote.errors.key?(:content)
      CONTENT_ERROR
    else
      quote.errors.full_messages.to_sentence.presence || CONTENT_ERROR
    end
  end
end
