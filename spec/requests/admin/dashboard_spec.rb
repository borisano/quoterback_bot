require "rails_helper"

RSpec.describe "Admin::Dashboard", type: :request do
  let(:username) { "admin" }
  let(:password) { "secret" }

  before do
    stub_const("ENV", ENV.to_h.merge("ADMIN_USERNAME" => username, "ADMIN_PASSWORD" => password))
  end

  def auth_headers
    credentials = Base64.encode64("#{username}:#{password}").strip
    { "HTTP_AUTHORIZATION" => "Basic #{credentials}" }
  end

  describe "GET /admin" do
    context "with valid credentials" do
      it "returns 200" do
        get admin_root_path, headers: auth_headers
        expect(response).to have_http_status(:ok)
      end

      it "shows user count" do
        create(:user)
        get admin_root_path, headers: auth_headers
        expect(response.body).to include("1")
      end
    end

    context "without credentials" do
      it "returns 401" do
        get admin_root_path
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context "with wrong credentials" do
      it "returns 401" do
        bad_creds = Base64.encode64("wrong:password").strip
        get admin_root_path, headers: { "HTTP_AUTHORIZATION" => "Basic #{bad_creds}" }
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context "with blank admin credentials configured" do
      before { stub_const("ENV", ENV.to_h.merge("ADMIN_USERNAME" => "", "ADMIN_PASSWORD" => "")) }

      it "returns 403" do
        get admin_root_path
        expect(response).to have_http_status(:forbidden)
      end
    end
  end
end
