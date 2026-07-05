class CreateDeliverySchedules < ActiveRecord::Migration[8.1]
  def change
    create_table :delivery_schedules do |t|
      t.references :user, null: false, foreign_key: true
      t.references :tag, foreign_key: true
      t.integer :hour, null: false
      t.integer :minute, null: false, default: 0
      t.boolean :enabled, null: false, default: true
      t.string  :label
      t.string  :pending_job_id
      t.timestamps
    end
    add_index :delivery_schedules, [ :enabled, :user_id ]
    add_index :delivery_schedules, :pending_job_id
  end
end
