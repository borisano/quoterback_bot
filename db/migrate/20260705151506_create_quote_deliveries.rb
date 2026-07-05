class CreateQuoteDeliveries < ActiveRecord::Migration[8.1]
  def change
    create_table :quote_deliveries do |t|
      t.references :user, null: false, foreign_key: true
      t.references :quote, foreign_key: { on_delete: :nullify }
      t.references :delivery_schedule, foreign_key: { on_delete: :nullify }
      t.date    :local_date, null: false
      t.string  :context
      t.datetime :delivered_at, null: false
      t.timestamps
    end
    add_index :quote_deliveries, [ :user_id, :delivery_schedule_id, :local_date ], unique: true, name: 'index_quote_deliveries_on_user_sched_date'
  end
end
