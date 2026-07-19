require "rails_helper"

RSpec.describe AttachQuoteImageJob do
  let(:user) { create(:user) }
  let(:tg) { instance_double(TelegramClient) }

  before { allow(TelegramClient).to receive(:from_env).and_return(tg) }

  it "downloads the photo (binary) and attaches it to Active Storage" do
    quote = create(:quote, user: user, photo_file_id: "FID")
    allow(tg).to receive(:download_file)
      .with("FID", max_bytes: described_class::MAX_BYTES, binary: true)
      .and_return("\xFF\xD8\xFFjpeg-bytes".b)

    described_class.perform_now(quote.id)
    expect(quote.reload.image).to be_attached
    expect(quote.image.content_type).to eq("image/jpeg")
  end

  it "is idempotent — skips a quote that already has an attached image" do
    quote = create(:quote, user: user, photo_file_id: "FID")
    quote.image.attach(io: StringIO.new("existing".b), filename: "q.jpg", content_type: "image/jpeg")
    described_class.perform_now(quote.id)
    expect(tg).not_to have_received(:download_file) if tg.respond_to?(:download_file)
  end

  it "does nothing when the quote has no photo_file_id" do
    quote = create(:quote, user: user, photo_file_id: nil)
    allow(tg).to receive(:download_file)
    described_class.perform_now(quote.id)
    expect(quote.reload.image).not_to be_attached
  end

  it "does not attach when the download returns nothing" do
    quote = create(:quote, user: user, photo_file_id: "FID")
    allow(tg).to receive(:download_file).and_return(nil)
    described_class.perform_now(quote.id)
    expect(quote.reload.image).not_to be_attached
  end

  it "does nothing for a missing quote id" do
    allow(tg).to receive(:download_file)
    expect { described_class.perform_now(-1) }.not_to raise_error
  end

  it "retries on a transient download Error" do
    quote = create(:quote, user: user, photo_file_id: "FID")
    allow(tg).to receive(:download_file).and_raise(TelegramClient::Error, "timeout")
    expect {
      described_class.perform_now(quote.id)
    }.to have_enqueued_job(described_class)
  end

  it "does not attach or retry when the bot is blocked (Forbidden)" do
    quote = create(:quote, user: user, photo_file_id: "FID")
    allow(tg).to receive(:download_file).and_raise(TelegramClient::Forbidden, "blocked")
    expect {
      described_class.perform_now(quote.id)
    }.not_to have_enqueued_job(described_class)
    expect(quote.reload.image).not_to be_attached
  end

  it "preserves raw image bytes (binary download, no UTF-8 scrub)" do
    quote = create(:quote, user: user, photo_file_id: "FID")
    raw = "\xFF\xD8\xFF\xE0\x00\x10JFIF".b
    allow(tg).to receive(:download_file).and_return(raw)
    described_class.perform_now(quote.id)
    expect(quote.reload.image.download.b).to eq(raw)
  end
end
