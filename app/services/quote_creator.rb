# The single choke point through which every quote is born. Centralizing
# creation here keeps validation messaging consistent across all capture paths
# (/add, awaiting_quote_text, confirm-on-text, and — later — import/photo) and
# gives the free-tier limit stub (plan §9.7) one place to live.
class QuoteCreator
  CONTENT_ERROR = "Quotes need to be 3–1000 characters."

  Result = Struct.new(:quote, :error_message, :limit_reached) do
    def success?
      error_message.nil?
    end

    def failure?
      !success?
    end

    def limit_reached?
      !!limit_reached
    end
  end

  def self.call(user:, content:, photo_file_id: nil)
    new(user: user, content: content, photo_file_id: photo_file_id).call
  end

  def initialize(user:, content:, photo_file_id: nil)
    @user = user
    @content = content.to_s.strip
    @photo_file_id = photo_file_id.presence
  end

  def call
    if limit_reached?
      return Result.new(
        nil,
        "You've reached the free limit of #{User::FREE_QUOTE_LIMIT} quotes. Delete one to add more.",
        true
      )
    end

    quote = @user.quotes.new(content: @content, photo_file_id: @photo_file_id)
    if quote.save
      Result.new(quote, nil, false)
    else
      Result.new(nil, human_error(quote), false)
    end
  end

  private

  # Free-tier cap, enforced here so no capture path (add, state, confirm, photo,
  # import) can bypass it (plan §9.7/N9).
  def limit_reached?
    !@user.premium? && @user.quotes.count >= User::FREE_QUOTE_LIMIT
  end

  def human_error(quote)
    if quote.errors.key?(:content)
      CONTENT_ERROR
    else
      quote.errors.full_messages.to_sentence.presence || CONTENT_ERROR
    end
  end
end
