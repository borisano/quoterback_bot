module Bot
  class QuotePresenter
    PAGE_SIZE = 10

    def initialize(quote)
      @quote = quote
    end

    def message_text
      build_text(budget: 4096)
    end

    def caption_text
      build_text(budget: 1024)
    end

    def list_preview
      content = @quote.content.truncate(120)
      lines = [ content ]
      lines << "— #{@quote.author}" if @quote.author.present?
      lines.join("\n")
    end

    private

    def build_text(budget:)
      parts = [ @quote.content ]
      parts << "— #{@quote.author}" if @quote.author.present?
      parts << "(#{@quote.source})" if @quote.source.present?
      parts.join("\n").truncate(budget)
    end
  end
end
