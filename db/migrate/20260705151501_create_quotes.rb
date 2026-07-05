class CreateQuotes < ActiveRecord::Migration[8.1]
  def change
    create_table :quotes do |t|
      t.references :user, null: false, foreign_key: true
      t.text    :content, null: false
      t.string  :author
      t.string  :source, limit: 200
      t.string  :photo_file_id
      t.boolean :favourited, null: false, default: false
      t.integer :times_delivered, null: false, default: 0
      t.datetime :last_delivered_at
      t.timestamps
    end
    add_index :quotes, [ :user_id, :created_at ]
  end
end
