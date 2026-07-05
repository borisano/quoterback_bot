class Tagging < ApplicationRecord
  belongs_to :quote
  belongs_to :tag

  validates :quote_id, uniqueness: { scope: :tag_id }
end
