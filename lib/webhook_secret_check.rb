# Fails production boot when TELEGRAM_WEBHOOK_SECRET is unset, so a misconfigured
# deploy can't silently run with webhook auth disabled (plan §13, L1/N2).
#
# Skipped during asset precompilation / Docker image build, which run under
# RAILS_ENV=production with SECRET_KEY_BASE_DUMMY=1 and no real secrets (N2).
module WebhookSecretCheck
  module_function

  def verify!(production:, secret:, dummy:)
    return unless production
    return if dummy.present?   # asset precompile / image build
    return if secret.present?

    raise "TELEGRAM_WEBHOOK_SECRET must be set in production — refusing to boot " \
          "with webhook authentication disabled."
  end
end
