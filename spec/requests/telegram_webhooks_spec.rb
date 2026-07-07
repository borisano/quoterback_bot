require "rails_helper"

RSpec.describe "Telegram webhook", type: :request do
  let(:payload) do
    {
      update_id: 1,
      message: { message_id: 1, chat: { id: 111 }, from: { id: 111, first_name: "T" }, text: "/ping" }
    }
  end

  # Never hit Telegram or run real dispatch logic in a controller spec.
  before { allow_any_instance_of(Bot::Dispatcher).to receive(:dispatch) }

  context "when a webhook secret is configured" do
    let(:secret) { "topsecret" }

    before { stub_const("ENV", ENV.to_h.merge("TELEGRAM_WEBHOOK_SECRET" => secret)) }

    it "returns 200 and dispatches with the correct secret header" do
      post "/telegram/webhook", params: payload, as: :json,
        headers: { "X-Telegram-Bot-Api-Secret-Token" => secret }
      expect(response).to have_http_status(:ok)
    end

    it "rejects a wrong secret header with 401 and does not dispatch" do
      expect_any_instance_of(Bot::Dispatcher).not_to receive(:dispatch)
      post "/telegram/webhook", params: payload, as: :json,
        headers: { "X-Telegram-Bot-Api-Secret-Token" => "wrong" }
      expect(response).to have_http_status(:unauthorized)
    end

    it "rejects a missing secret header with 401" do
      post "/telegram/webhook", params: payload, as: :json
      expect(response).to have_http_status(:unauthorized)
    end
  end

  context "when no webhook secret is configured (dev/test convenience)" do
    before { stub_const("ENV", ENV.to_h.merge("TELEGRAM_WEBHOOK_SECRET" => "")) }

    it "skips verification and returns 200" do
      post "/telegram/webhook", params: payload, as: :json
      expect(response).to have_http_status(:ok)
    end
  end

  context "resilience — always 200 so Telegram never retry-storms (M15)" do
    before { stub_const("ENV", ENV.to_h.merge("TELEGRAM_WEBHOOK_SECRET" => "")) }

    it "returns 200 even when the dispatcher raises" do
      allow_any_instance_of(Bot::Dispatcher).to receive(:dispatch).and_raise(StandardError, "boom")
      post "/telegram/webhook", params: payload, as: :json
      expect(response).to have_http_status(:ok)
    end

    it "returns 200 even when UpdateParser raises" do
      allow(Bot::UpdateParser).to receive(:parse).and_raise(StandardError, "parser boom")
      post "/telegram/webhook", params: payload, as: :json
      expect(response).to have_http_status(:ok)
    end

    it "returns 200 for an unrecognized/empty update body" do
      post "/telegram/webhook", params: { update_id: 2 }, as: :json
      expect(response).to have_http_status(:ok)
    end
  end
end
