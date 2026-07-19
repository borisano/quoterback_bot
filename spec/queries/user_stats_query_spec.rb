require "rails_helper"

RSpec.describe UserStatsQuery do
  let(:user) { create(:user, :with_timezone) }

  it "counts total quotes, favourites, images and distinct authors scoped to the user" do
    create(:quote, user: user, author: "Seneca")
    create(:quote, user: user, author: "Seneca") # same author → still 1 distinct
    create(:quote, user: user, author: "Marcus", favourited: true)
    create(:quote, user: user, author: nil, photo_file_id: "FID")
    create(:quote, user: create(:user, telegram_chat_id: 999), author: "Someone Else") # other user

    stats = described_class.call(user)
    expect(stats).to have_attributes(
      total_quotes: 4,
      distinct_authors: 2,
      favourites: 1,
      with_images: 1
    )
  end

  it "reports the current streak and delivery count" do
    user.update!(streak_count: 5)
    q = create(:quote, user: user)
    create(:quote_delivery, user: user, quote: q)
    create(:quote_delivery, user: user, quote: q)

    stats = described_class.call(user)
    expect(stats.current_streak).to eq(5)
    expect(stats.quotes_delivered).to eq(2)
  end

  it "returns up to three top tags as [name, count] pairs, most-used first" do
    q1 = create(:quote, user: user)
    q2 = create(:quote, user: user)
    stoic = create(:tag, user: user, name: "stoic")
    funny = create(:tag, user: user, name: "funny")
    q1.taggings.create!(tag: stoic)
    q2.taggings.create!(tag: stoic)
    q1.taggings.create!(tag: funny)

    stats = described_class.call(user)
    expect(stats.top_tags.first).to eq([ "stoic", 2 ])
    expect(stats.top_tags.map(&:first)).to contain_exactly("stoic", "funny")
  end

  it "excludes tags that were created but never applied (no count-0 top tags)" do
    q = create(:quote, user: user)
    used = create(:tag, user: user, name: "used")
    create(:tag, user: user, name: "unused")
    q.taggings.create!(tag: used)

    stats = described_class.call(user)
    expect(stats.top_tags.map(&:first)).to eq([ "used" ])
  end

  it "handles an empty collection" do
    stats = described_class.call(user)
    expect(stats).to have_attributes(total_quotes: 0, distinct_authors: 0, top_tags: [])
  end
end
