require "rails_helper"
require "rake"

RSpec.describe "bot:quote_now rake task" do
  before(:all) do
    Rake.application.rake_require("tasks/bot", [ Rails.root.join("lib").to_s ])
    Rake::Task.define_task(:environment)
  end

  let(:task) { Rake::Task["bot:quote_now"] }
  let(:client) { double("TelegramClient") } # rubocop:disable RSpec/VerifiedDoubles

  before do
    allow(TelegramClient).to receive(:from_env).and_return(client)
    allow(client).to receive(:send_message)
  end

  after { task.reenable }

  it "sends a random quote to the user's chat" do
    user = create(:user, telegram_chat_id: 555)
    create(:quote, user: user, content: "A meaningful test quote.")
    task.invoke("555")
    expect(client).to have_received(:send_message).with(
      hash_including(chat_id: 555, text: a_string_including("A meaningful test quote."))
    )
  end

  it "aborts when the user does not exist" do
    expect { task.invoke("999999") }.to raise_error(SystemExit)
    expect(client).not_to have_received(:send_message)
  end

  it "aborts when the user has no quotes" do
    create(:user, telegram_chat_id: 556)
    expect { task.invoke("556") }.to raise_error(SystemExit)
    expect(client).not_to have_received(:send_message)
  end
end
