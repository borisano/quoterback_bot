require "rails_helper"
require "webhook_secret_check"

RSpec.describe WebhookSecretCheck do
  describe ".verify!" do
    it "raises in production when the secret is blank and it is not a dummy build" do
      expect {
        described_class.verify!(production: true, secret: "", dummy: nil)
      }.to raise_error(/TELEGRAM_WEBHOOK_SECRET/)
    end

    it "raises when the secret is nil in production" do
      expect {
        described_class.verify!(production: true, secret: nil, dummy: nil)
      }.to raise_error(/TELEGRAM_WEBHOOK_SECRET/)
    end

    it "does not raise during a dummy asset build even if the secret is blank" do
      expect {
        described_class.verify!(production: true, secret: "", dummy: "1")
      }.not_to raise_error
    end

    it "does not raise in production when the secret is present" do
      expect {
        described_class.verify!(production: true, secret: "s3cr3t", dummy: nil)
      }.not_to raise_error
    end

    it "does not raise outside production" do
      expect {
        described_class.verify!(production: false, secret: "", dummy: nil)
      }.not_to raise_error
    end
  end
end
