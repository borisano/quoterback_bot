require "rails_helper"

RSpec.describe Bot::QuotePresenter do
  let(:user) { create(:user) }
  let(:quote) { create(:quote, user: user, content: "Do what you love.", author: "Steve Jobs", source: "Commencement Speech") }

  subject(:presenter) { described_class.new(quote) }

  describe "#message_text" do
    it "includes the content" do
      expect(presenter.message_text).to include("Do what you love.")
    end

    it "includes author with em dash" do
      expect(presenter.message_text).to include("— Steve Jobs")
    end

    it "includes source in parentheses" do
      expect(presenter.message_text).to include("(Commencement Speech)")
    end

    it "truncates at 4096 chars" do
      long_quote = build(:quote, user: user, content: "x" * 5000, author: nil)
      text = described_class.new(long_quote).message_text
      expect(text.length).to be <= 4096
    end
  end

  describe "#caption_text" do
    it "truncates at 1024 chars" do
      long_quote = build(:quote, user: user, content: "y" * 2000, author: nil)
      text = described_class.new(long_quote).caption_text
      expect(text.length).to be <= 1024
    end
  end

  describe "#list_preview" do
    it "truncates content at 120 chars" do
      long_quote = build(:quote, user: user, content: "z" * 200, author: nil)
      preview = described_class.new(long_quote).list_preview
      expect(preview.length).to be <= 130  # 120 + "..." + some leeway
    end

    it "includes author with em dash" do
      expect(presenter.list_preview).to include("— Steve Jobs")
    end
  end
end
