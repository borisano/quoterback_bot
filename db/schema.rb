# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_07_05_151506) do
  create_table "delivery_schedules", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.boolean "enabled", default: true, null: false
    t.integer "hour", null: false
    t.string "label"
    t.integer "minute", default: 0, null: false
    t.string "pending_job_id"
    t.integer "tag_id"
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["enabled", "user_id"], name: "index_delivery_schedules_on_enabled_and_user_id"
    t.index ["pending_job_id"], name: "index_delivery_schedules_on_pending_job_id"
    t.index ["tag_id"], name: "index_delivery_schedules_on_tag_id"
    t.index ["user_id"], name: "index_delivery_schedules_on_user_id"
  end

  create_table "quote_deliveries", force: :cascade do |t|
    t.string "context"
    t.datetime "created_at", null: false
    t.datetime "delivered_at", null: false
    t.integer "delivery_schedule_id"
    t.date "local_date", null: false
    t.integer "quote_id"
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["delivery_schedule_id"], name: "index_quote_deliveries_on_delivery_schedule_id"
    t.index ["quote_id"], name: "index_quote_deliveries_on_quote_id"
    t.index ["user_id", "delivery_schedule_id", "local_date"], name: "index_quote_deliveries_on_user_sched_date", unique: true
    t.index ["user_id"], name: "index_quote_deliveries_on_user_id"
  end

  create_table "quotes", force: :cascade do |t|
    t.string "author"
    t.text "content", null: false
    t.datetime "created_at", null: false
    t.boolean "favourited", default: false, null: false
    t.datetime "last_delivered_at"
    t.string "photo_file_id"
    t.string "source", limit: 200
    t.integer "times_delivered", default: 0, null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["user_id", "created_at"], name: "index_quotes_on_user_id_and_created_at"
    t.index ["user_id"], name: "index_quotes_on_user_id"
  end

  create_table "taggings", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "quote_id", null: false
    t.integer "tag_id", null: false
    t.datetime "updated_at", null: false
    t.index ["quote_id", "tag_id"], name: "index_taggings_on_quote_id_and_tag_id", unique: true
    t.index ["quote_id"], name: "index_taggings_on_quote_id"
    t.index ["tag_id"], name: "index_taggings_on_tag_id"
  end

  create_table "tags", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["user_id", "name"], name: "index_tags_on_user_id_and_name", unique: true
    t.index ["user_id"], name: "index_tags_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.string "dnd_weekdays"
    t.string "first_name"
    t.datetime "last_interaction_at"
    t.string "locale"
    t.string "state"
    t.integer "streak_count", default: 0, null: false
    t.date "streak_last_date"
    t.bigint "telegram_chat_id", null: false
    t.string "telegram_language_code"
    t.string "timezone"
    t.datetime "updated_at", null: false
    t.index ["telegram_chat_id"], name: "index_users_on_telegram_chat_id", unique: true
  end

  add_foreign_key "delivery_schedules", "tags"
  add_foreign_key "delivery_schedules", "users"
  add_foreign_key "quote_deliveries", "delivery_schedules", on_delete: :nullify
  add_foreign_key "quote_deliveries", "quotes", on_delete: :nullify
  add_foreign_key "quote_deliveries", "users"
  add_foreign_key "quotes", "users"
  add_foreign_key "taggings", "quotes"
  add_foreign_key "taggings", "tags"
  add_foreign_key "tags", "users"
end
