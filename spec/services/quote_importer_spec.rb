require "rails_helper"

RSpec.describe QuoteImporter do
  let(:user) { create(:user) }

  def result_for(content)
    described_class.call(user: user, content: content)
  end

  it "creates one quote per non-blank line" do
    content = "First quote here\nSecond quote here\nThird quote here"
    expect { result_for(content) }.to change { user.quotes.count }.by(3)
  end

  it "reports the imported count" do
    result = result_for("First quote here\nSecond quote here")
    expect(result).to have_attributes(success?: true, imported: 2, skipped: 0)
  end

  it "trims whitespace and skips blank lines" do
    content = "  Padded quote line  \n\n\n   \nAnother good line here"
    expect { result_for(content) }.to change { user.quotes.count }.by(2)
    expect(user.quotes.pluck(:content)).to include("Padded quote line")
  end

  it "handles CRLF line endings" do
    content = "Windows line one here\r\nWindows line two here"
    expect { result_for(content) }.to change { user.quotes.count }.by(2)
  end

  it "skips lines that fail validation (too short) and counts them" do
    content = "ok\nA perfectly valid quote line" # "ok" is under the 3-char minimum
    result = result_for(content)
    expect(result).to have_attributes(imported: 1, skipped: 1)
    expect(user.quotes.pluck(:content)).to eq([ "A perfectly valid quote line" ])
  end

  it "skips lines that duplicate an existing quote" do
    create(:quote, user: user, content: "Already in the collection")
    result = result_for("Already in the collection\nA brand new quote line")
    expect(result).to have_attributes(imported: 1, skipped: 1)
  end

  it "de-duplicates repeated lines within the same file" do
    content = "Same line repeated twice\nSame line repeated twice"
    result = result_for(content)
    expect(result).to have_attributes(imported: 1, skipped: 1)
  end

  it "scrubs invalid UTF-8 bytes instead of blowing up" do
    content = "Valid quote before bad byte \xFF here".dup.force_encoding("ASCII-8BIT")
    expect { result_for(content) }.not_to raise_error
    expect(user.quotes.count).to eq(1)
  end

  it "rejects a file over the byte cap" do
    big = ("A valid quote line here\n" * 20_000) # > 256 KB
    result = result_for(big)
    expect(result).to have_attributes(failure?: true)
    expect(result.error_message).to include("256 KB")
    expect(user.quotes.count).to eq(0)
  end

  it "rejects a file over the line cap" do
    many = (1..(described_class::MAX_LINES + 1)).map { |i| "Quote number #{i} in the file" }.join("\n")
    result = result_for(many)
    expect(result).to have_attributes(failure?: true)
    expect(result.error_message).to include("capped")
    expect(user.quotes.count).to eq(0)
  end

  it "reports an empty file as a failure" do
    result = result_for("\n\n   \n")
    expect(result).to have_attributes(failure?: true)
    expect(result.error_message).to be_present
  end
end
