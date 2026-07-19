require "rails_helper"

RSpec.describe Bot::UpdateParser do
  describe ".parse" do
    context "with a plain message hash" do
      let(:update) do
        {
          message: {
            message_id: 555,
            chat: { id: 123_456 },
            from: { id: 123_456, first_name: "Alice", language_code: "en" },
            text: "/ping"
          }
        }
      end

      it "returns a ParsedUpdate with the correct chat_id" do
        result = described_class.parse(update)
        expect(result.chat_id).to eq(123_456)
      end

      it "returns the text" do
        result = described_class.parse(update)
        expect(result.text).to eq("/ping")
      end

      it "returns first_name" do
        result = described_class.parse(update)
        expect(result.first_name).to eq("Alice")
      end

      it "has nil callback_data" do
        result = described_class.parse(update)
        expect(result.callback_data).to be_nil
      end

      it "returns from_id" do
        result = described_class.parse(update)
        expect(result.from_id).to eq(123_456)
      end

      it "returns message_id" do
        result = described_class.parse(update)
        expect(result.message_id).to eq(555)
      end
    end

    context "with a callback_query hash" do
      let(:update) do
        {
          callback_query: {
            id: "42",
            data: "some_action",
            from: { id: 4242, first_name: "Bob", language_code: "fr" },
            message: { message_id: 777, chat: { id: 789 } }
          }
        }
      end

      it "returns callback_data" do
        result = described_class.parse(update)
        expect(result.callback_data).to eq("some_action")
      end

      it "returns the chat_id from the nested message" do
        result = described_class.parse(update)
        expect(result.chat_id).to eq(789)
      end

      it "has nil text" do
        result = described_class.parse(update)
        expect(result.text).to be_nil
      end

      it "returns from_id" do
        result = described_class.parse(update)
        expect(result.from_id).to eq(4242)
      end

      it "returns message_id from the nested message" do
        result = described_class.parse(update)
        expect(result.message_id).to eq(777)
      end
    end

    context "with a document message (G5)" do
      let(:update) do
        {
          message: {
            message_id: 900,
            chat: { id: 555 },
            from: { id: 555, first_name: "Ann" },
            document: { file_id: "FID123", file_name: "quotes.txt", file_size: 2048, mime_type: "text/plain" }
          }
        }
      end

      it "extracts the document metadata" do
        result = described_class.parse(update)
        expect(result.document).to eq(
          file_id: "FID123", file_name: "quotes.txt", file_size: 2048, mime_type: "text/plain"
        )
      end

      it "leaves document nil for a plain text message" do
        result = described_class.parse(message: { chat: { id: 1 }, from: { id: 1 }, text: "hi" })
        expect(result.document).to be_nil
      end
    end

    context "with a photo message (G4)" do
      let(:update) do
        {
          message: {
            message_id: 901,
            chat: { id: 555 },
            from: { id: 555, first_name: "Ann" },
            caption: "A framed quote",
            photo: [
              { file_id: "thumb", file_size: 1_000 },
              { file_id: "medium", file_size: 20_000 },
              { file_id: "largest", file_size: 90_000 }
            ]
          }
        }
      end

      it "takes the largest PhotoSize's file_id (never the thumbnail)" do
        expect(described_class.parse(update).photo_file_id).to eq("largest")
      end

      it "extracts the caption" do
        expect(described_class.parse(update).caption).to eq("A framed quote")
      end

      it "leaves photo_file_id nil for a plain text message" do
        result = described_class.parse(message: { chat: { id: 1 }, from: { id: 1 }, text: "hi" })
        expect(result.photo_file_id).to be_nil
      end
    end

    context "with an empty hash" do
      it "returns nil" do
        expect(described_class.parse({})).to be_nil
      end
    end
  end
end
