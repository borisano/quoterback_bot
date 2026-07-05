class CreateTaggings < ActiveRecord::Migration[8.1]
  def change
    create_table :taggings do |t|
      t.references :quote, null: false, foreign_key: true
      t.references :tag, null: false, foreign_key: true
      t.timestamps
    end
    add_index :taggings, [:quote_id, :tag_id], unique: true
  end
end
