require "webmock/rspec"

# Block all real HTTP connections in the test suite. External services
# (Telegram API) must be stubbed via WebMock or VCR.
WebMock.disable_net_connect!(allow_localhost: true)
