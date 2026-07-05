class CreateUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :users do |t|
      t.bigint  :telegram_chat_id, null: false
      t.string  :first_name
      t.string  :telegram_language_code
      t.string  :locale
      t.string  :timezone
      t.string  :state
      t.boolean :active, null: false, default: true
      t.integer :streak_count, null: false, default: 0
      t.date    :streak_last_date
      t.string  :dnd_weekdays
      t.datetime :last_interaction_at
      t.timestamps
    end
    add_index :users, :telegram_chat_id, unique: true
  end
end
