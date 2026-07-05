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

    context "with an empty hash" do
      it "returns nil" do
        expect(described_class.parse({})).to be_nil
      end
    end
  end
end
