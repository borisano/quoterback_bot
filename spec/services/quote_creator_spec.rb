require "rails_helper"

RSpec.describe QuoteCreator do
  let(:user) { create(:user) }

  describe ".call" do
    context "with valid content" do
      it "creates a quote scoped to the user" do
        expect {
          described_class.call(user: user, content: "A genuinely valid quote.")
        }.to change { user.quotes.count }.by(1)
      end

      it "returns a successful result carrying the quote" do
        result = described_class.call(user: user, content: "A genuinely valid quote.")
        expect(result).to be_success
        expect(result.quote).to be_a(Quote)
        expect(result.quote).to be_persisted
        expect(result.error_message).to be_nil
      end

      it "strips surrounding whitespace" do
        result = described_class.call(user: user, content: "  padded quote  ")
        expect(result.quote.content).to eq("padded quote")
      end

      it "stores an optional photo_file_id (G4)" do
        result = described_class.call(user: user, content: "A quote with a picture", photo_file_id: "FID123")
        expect(result.quote.photo_file_id).to eq("FID123")
      end

      it "leaves photo_file_id nil when not supplied" do
        result = described_class.call(user: user, content: "A plain quote here")
        expect(result.quote.photo_file_id).to be_nil
      end
    end

    context "with content that is too short" do
      it "does not create a quote" do
        expect {
          described_class.call(user: user, content: "hi")
        }.not_to change { user.quotes.count }
      end

      it "returns a failure with a human message" do
        result = described_class.call(user: user, content: "hi")
        expect(result).not_to be_success
        expect(result.quote).to be_nil
        expect(result.error_message).to include("3")
        expect(result.error_message).to include("1000")
      end
    end

    context "with content that is too long" do
      it "does not create a quote and reports a human message" do
        result = described_class.call(user: user, content: "x" * 1001)
        expect(result).not_to be_success
        expect(user.quotes.count).to eq(0)
        expect(result.error_message).to include("1000")
      end
    end

    context "with blank content" do
      it "fails gracefully" do
        result = described_class.call(user: user, content: "   ")
        expect(result).not_to be_success
        expect(result.error_message).to be_present
      end

      it "handles nil content without raising" do
        expect { described_class.call(user: user, content: nil) }.not_to raise_error
      end
    end

    context "at the free-tier quote limit (G8, plan §9.7)" do
      before { create_list(:quote, User::FREE_QUOTE_LIMIT, user: user) }

      it "does not create another quote for a non-premium user" do
        expect {
          described_class.call(user: user, content: "One quote over the line")
        }.not_to change { user.quotes.count }
      end

      it "returns a limit_reached failure with a self-service message" do
        result = described_class.call(user: user, content: "One quote over the line")
        expect(result).to have_attributes(success?: false, limit_reached?: true)
        expect(result.error_message).to include("free limit").and include("20")
      end

      it "lets a premium user keep adding" do
        allow(user).to receive(:premium?).and_return(true)
        expect {
          described_class.call(user: user, content: "Premium keeps going")
        }.to change { user.quotes.count }.by(1)
      end
    end
  end
end
