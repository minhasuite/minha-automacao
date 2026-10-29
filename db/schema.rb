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

ActiveRecord::Schema[8.1].define(version: 2026_10_29_000001) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pg_trgm"

  create_table "active_storage_attachments", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "name", null: false
    t.string "record_type", null: false
    t.uuid "record_id", null: false
    t.uuid "blob_id", null: false
    t.datetime "created_at", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "key", null: false
    t.string "filename", null: false
    t.string "content_type"
    t.text "metadata"
    t.string "service_name", null: false
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.datetime "created_at", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "ai_plan_features", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "feature", null: false
    t.string "plan", null: false
    t.string "tier"
    t.integer "limit"
    t.boolean "available", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["feature", "plan"], name: "index_ai_plan_features_on_feature_and_plan", unique: true
  end

  create_table "ai_tier_configs", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "tier", null: false
    t.string "provider", null: false
    t.string "model", null: false
    t.string "effort"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["tier"], name: "index_ai_tier_configs_on_tier", unique: true
  end

  create_table "ai_usages", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "tenant_id", null: false
    t.string "feature", null: false
    t.date "period", null: false
    t.integer "count", default: 0, null: false
    t.integer "input_tokens", default: 0, null: false
    t.integer "output_tokens", default: 0, null: false
    t.string "model"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "feature", "period"], name: "index_ai_usages_on_tenant_id_and_feature_and_period", unique: true
    t.index ["tenant_id"], name: "index_ai_usages_on_tenant_id"
  end

  create_table "api_tokens", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "user_id", null: false
    t.string "access_token_digest", null: false
    t.string "refresh_token_digest", null: false
    t.string "previous_refresh_token_digest"
    t.datetime "access_expires_at", null: false
    t.datetime "refresh_expires_at", null: false
    t.string "device_name"
    t.datetime "last_used_at"
    t.datetime "revoked_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["access_token_digest"], name: "index_api_tokens_on_access_token_digest", unique: true
    t.index ["previous_refresh_token_digest"], name: "index_api_tokens_on_previous_refresh_token_digest"
    t.index ["refresh_token_digest"], name: "index_api_tokens_on_refresh_token_digest", unique: true
    t.index ["user_id"], name: "index_api_tokens_on_user_id"
  end

  create_table "areas", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "tenant_id", null: false
    t.uuid "site_id", null: false
    t.uuid "parent_id"
    t.string "name", null: false
    t.string "kind", default: "room", null: false
    t.string "icon"
    t.string "background"
    t.integer "position", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["parent_id"], name: "index_areas_on_parent_id"
    t.index ["site_id"], name: "index_areas_on_site_id"
    t.index ["tenant_id"], name: "index_areas_on_tenant_id"
  end

  create_table "audit_events", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "tenant_id"
    t.uuid "user_id"
    t.string "action", null: false
    t.string "auditable_type", null: false
    t.uuid "auditable_id"
    t.jsonb "details", default: {}, null: false
    t.datetime "created_at", null: false
    t.index ["auditable_type", "auditable_id"], name: "index_audit_events_on_auditable_type_and_auditable_id"
    t.index ["tenant_id"], name: "index_audit_events_on_tenant_id"
  end

  create_table "device_tokens", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "user_id", null: false
    t.string "token", null: false
    t.string "platform", default: "android", null: false
    t.datetime "last_seen_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["token"], name: "index_device_tokens_on_token", unique: true
    t.index ["user_id"], name: "index_device_tokens_on_user_id"
  end

  create_table "devices", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "tenant_id", null: false
    t.uuid "site_id", null: false
    t.uuid "area_id"
    t.string "driver", default: "virtual", null: false
    t.string "name", null: false
    t.string "manufacturer"
    t.string "model"
    t.string "serial"
    t.string "external_id"
    t.jsonb "address", default: {}, null: false
    t.string "firmware"
    t.string "status", default: "online", null: false
    t.datetime "last_seen_at"
    t.uuid "battery_point_id"
    t.boolean "disabled", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["area_id"], name: "index_devices_on_area_id"
    t.index ["site_id"], name: "index_devices_on_site_id"
    t.index ["tenant_id"], name: "index_devices_on_tenant_id"
  end

  create_table "feature_flags", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "key", null: false
    t.boolean "enabled", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_feature_flags_on_key", unique: true
  end

  create_table "invites", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "tenant_id", null: false
    t.uuid "created_by_id"
    t.uuid "accepted_by_id"
    t.string "role", default: "member", null: false
    t.string "code_digest", null: false
    t.datetime "expires_at", null: false
    t.datetime "accepted_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["accepted_by_id"], name: "index_invites_on_accepted_by_id"
    t.index ["code_digest"], name: "index_invites_on_code_digest", unique: true
    t.index ["created_by_id"], name: "index_invites_on_created_by_id"
    t.index ["tenant_id"], name: "index_invites_on_tenant_id"
  end

  create_table "model_prices", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "provider", null: false
    t.string "model", null: false
    t.decimal "input_per_mtok", precision: 10, scale: 4, default: "0.0", null: false
    t.decimal "output_per_mtok", precision: 10, scale: 4, default: "0.0", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["provider", "model"], name: "index_model_prices_on_provider_and_model", unique: true
  end

  create_table "notifications", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "tenant_id", null: false
    t.uuid "user_id"
    t.string "kind", null: false
    t.string "title", null: false
    t.string "body"
    t.jsonb "data", default: {}, null: false
    t.string "dedup_key"
    t.datetime "read_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "created_at"], name: "index_notifications_on_tenant_id_and_created_at"
    t.index ["tenant_id", "dedup_key"], name: "index_notifications_on_tenant_id_and_dedup_key", unique: true, where: "(dedup_key IS NOT NULL)"
    t.index ["tenant_id"], name: "index_notifications_on_tenant_id"
    t.index ["user_id"], name: "index_notifications_on_user_id"
  end

  create_table "points", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "tenant_id", null: false
    t.uuid "site_id", null: false
    t.uuid "device_id", null: false
    t.uuid "area_id"
    t.string "key", null: false
    t.string "name", null: false
    t.string "icon"
    t.string "capability", null: false
    t.string "data_type"
    t.string "device_class"
    t.string "state_class"
    t.string "unit"
    t.jsonb "options", default: [], null: false
    t.decimal "min"
    t.decimal "max"
    t.decimal "step"
    t.boolean "writable", default: false, null: false
    t.jsonb "address", default: {}, null: false
    t.decimal "scale", default: "1.0", null: false
    t.decimal "offset", default: "0.0", null: false
    t.decimal "deadband"
    t.string "history", default: "on_change", null: false
    t.integer "history_interval_s"
    t.integer "retention_days"
    t.integer "pulse_ms"
    t.integer "max_on_s"
    t.string "confirm"
    t.string "risk", default: "normal", null: false
    t.jsonb "expose", default: {}, null: false
    t.jsonb "value"
    t.string "quality", default: "good", null: false
    t.datetime "changed_at"
    t.datetime "reported_at"
    t.boolean "hidden", default: false, null: false
    t.boolean "disabled", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["area_id"], name: "index_points_on_area_id"
    t.index ["device_id"], name: "index_points_on_device_id"
    t.index ["site_id", "key"], name: "index_points_on_site_id_and_key", unique: true
    t.index ["site_id"], name: "index_points_on_site_id"
    t.index ["tenant_id"], name: "index_points_on_tenant_id"
  end

  create_table "service_api_keys", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "user_id", null: false
    t.string "name", null: false
    t.string "token_digest", null: false
    t.string "scopes", default: [], null: false, array: true
    t.datetime "expires_at"
    t.datetime "last_used_at"
    t.datetime "revoked_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["token_digest"], name: "index_service_api_keys_on_token_digest", unique: true
    t.index ["user_id"], name: "index_service_api_keys_on_user_id"
  end

  create_table "site_memberships", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "tenant_id", null: false
    t.uuid "site_id", null: false
    t.uuid "user_id", null: false
    t.string "role", default: "resident", null: false
    t.uuid "area_ids", default: [], null: false, array: true
    t.datetime "expires_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["site_id", "user_id"], name: "index_site_memberships_on_site_id_and_user_id", unique: true
    t.index ["site_id"], name: "index_site_memberships_on_site_id"
    t.index ["tenant_id"], name: "index_site_memberships_on_tenant_id"
    t.index ["user_id"], name: "index_site_memberships_on_user_id"
  end

  create_table "sites", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "tenant_id", null: false
    t.string "name", null: false
    t.string "kind", default: "home", null: false
    t.string "timezone", default: "America/Sao_Paulo", null: false
    t.string "address"
    t.decimal "latitude", precision: 9, scale: 6
    t.decimal "longitude", precision: 9, scale: 6
    t.string "wallpaper"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id"], name: "index_sites_on_tenant_id"
  end

  create_table "solid_cache_entries", force: :cascade do |t|
    t.binary "key", null: false
    t.binary "value", null: false
    t.datetime "created_at", null: false
    t.bigint "key_hash", null: false
    t.integer "byte_size", null: false
    t.index ["byte_size"], name: "index_solid_cache_entries_on_byte_size"
    t.index ["key_hash", "byte_size"], name: "index_solid_cache_entries_on_key_hash_and_byte_size"
    t.index ["key_hash"], name: "index_solid_cache_entries_on_key_hash", unique: true
  end

  create_table "solid_queue_batch_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.bigint "batch_id", null: false
    t.datetime "created_at", null: false
    t.index ["batch_id"], name: "index_solid_queue_batch_executions_on_batch_id"
    t.index ["job_id"], name: "index_solid_queue_batch_executions_on_job_id", unique: true
  end

  create_table "solid_queue_batches", force: :cascade do |t|
    t.string "active_job_batch_id"
    t.string "description"
    t.text "on_finish"
    t.text "on_success"
    t.text "on_failure"
    t.text "metadata"
    t.integer "total_jobs", default: 0, null: false
    t.integer "completed_jobs", default: 0, null: false
    t.integer "failed_jobs", default: 0, null: false
    t.datetime "enqueued_at"
    t.datetime "finished_at"
    t.datetime "failed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["active_job_batch_id"], name: "index_solid_queue_batches_on_active_job_batch_id", unique: true
    t.index ["finished_at"], name: "index_solid_queue_batches_on_finished_at"
  end

  create_table "solid_queue_blocked_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.string "concurrency_key", null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.index ["concurrency_key", "priority", "job_id"], name: "index_solid_queue_blocked_executions_for_release"
    t.index ["expires_at", "concurrency_key"], name: "index_solid_queue_blocked_executions_for_maintenance"
    t.index ["job_id"], name: "index_solid_queue_blocked_executions_on_job_id", unique: true
  end

  create_table "solid_queue_claimed_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.bigint "process_id"
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_claimed_executions_on_job_id", unique: true
    t.index ["process_id", "job_id"], name: "index_solid_queue_claimed_executions_on_process_id_and_job_id"
  end

  create_table "solid_queue_failed_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.text "error"
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_failed_executions_on_job_id", unique: true
  end

  create_table "solid_queue_jobs", force: :cascade do |t|
    t.string "queue_name", null: false
    t.string "class_name", null: false
    t.text "arguments"
    t.integer "priority", default: 0, null: false
    t.string "active_job_id"
    t.datetime "scheduled_at"
    t.datetime "finished_at"
    t.string "concurrency_key"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "batch_id"
    t.index ["active_job_id"], name: "index_solid_queue_jobs_on_active_job_id"
    t.index ["batch_id"], name: "index_solid_queue_jobs_on_batch_id"
    t.index ["class_name"], name: "index_solid_queue_jobs_on_class_name"
    t.index ["finished_at"], name: "index_solid_queue_jobs_on_finished_at"
    t.index ["queue_name", "finished_at"], name: "index_solid_queue_jobs_for_filtering"
    t.index ["scheduled_at", "finished_at"], name: "index_solid_queue_jobs_for_alerting"
  end

  create_table "solid_queue_pauses", force: :cascade do |t|
    t.string "queue_name", null: false
    t.datetime "created_at", null: false
    t.index ["queue_name"], name: "index_solid_queue_pauses_on_queue_name", unique: true
  end

  create_table "solid_queue_processes", force: :cascade do |t|
    t.string "kind", null: false
    t.datetime "last_heartbeat_at", null: false
    t.bigint "supervisor_id"
    t.integer "pid", null: false
    t.string "hostname"
    t.text "metadata"
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.index ["last_heartbeat_at"], name: "index_solid_queue_processes_on_last_heartbeat_at"
    t.index ["name", "supervisor_id"], name: "index_solid_queue_processes_on_name_and_supervisor_id", unique: true
    t.index ["supervisor_id"], name: "index_solid_queue_processes_on_supervisor_id"
  end

  create_table "solid_queue_ready_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_ready_executions_on_job_id", unique: true
    t.index ["priority", "job_id"], name: "index_solid_queue_poll_all"
    t.index ["queue_name", "priority", "job_id"], name: "index_solid_queue_poll_by_queue"
  end

  create_table "solid_queue_recurring_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "task_key", null: false
    t.datetime "run_at", null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_recurring_executions_on_job_id", unique: true
    t.index ["task_key", "run_at"], name: "index_solid_queue_recurring_executions_on_task_key_and_run_at", unique: true
  end

  create_table "solid_queue_recurring_tasks", force: :cascade do |t|
    t.string "key", null: false
    t.string "schedule", null: false
    t.string "command", limit: 2048
    t.string "class_name"
    t.text "arguments"
    t.string "queue_name"
    t.integer "priority", default: 0
    t.boolean "static", default: true, null: false
    t.text "description"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_solid_queue_recurring_tasks_on_key", unique: true
    t.index ["static"], name: "index_solid_queue_recurring_tasks_on_static"
  end

  create_table "solid_queue_scheduled_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.datetime "scheduled_at", null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_scheduled_executions_on_job_id", unique: true
    t.index ["scheduled_at", "priority", "job_id"], name: "index_solid_queue_dispatch_all"
  end

  create_table "solid_queue_semaphores", force: :cascade do |t|
    t.string "key", null: false
    t.integer "value", default: 1, null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["expires_at"], name: "index_solid_queue_semaphores_on_expires_at"
    t.index ["key", "value"], name: "index_solid_queue_semaphores_on_key_and_value"
    t.index ["key"], name: "index_solid_queue_semaphores_on_key", unique: true
  end

  create_table "subscriptions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "tenant_id", null: false
    t.uuid "user_id"
    t.string "source", limit: 20, null: false
    t.string "external_id", null: false
    t.string "product_id", limit: 100
    t.string "base_plan_id", limit: 100
    t.string "offer_id", limit: 100
    t.string "plan", limit: 20, default: "free", null: false
    t.string "status", limit: 20, null: false
    t.boolean "auto_renewing"
    t.boolean "trial", default: false, null: false
    t.datetime "expires_at"
    t.string "linked_external_id"
    t.datetime "verified_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["source", "external_id"], name: "index_subscriptions_on_source_and_external_id", unique: true
    t.index ["tenant_id"], name: "index_subscriptions_on_tenant_id"
    t.index ["user_id"], name: "index_subscriptions_on_user_id"
  end

  create_table "taggings", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "tenant_id", null: false
    t.uuid "tag_id", null: false
    t.string "taggable_type", null: false
    t.uuid "taggable_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["tag_id", "taggable_type", "taggable_id"], name: "index_taggings_uniqueness", unique: true
    t.index ["tag_id"], name: "index_taggings_on_tag_id"
    t.index ["taggable_type", "taggable_id"], name: "index_taggings_on_taggable"
    t.index ["tenant_id"], name: "index_taggings_on_tenant_id"
  end

  create_table "tags", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "tenant_id", null: false
    t.string "name", null: false
    t.string "color"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "name"], name: "index_tags_on_tenant_id_and_name", unique: true
    t.index ["tenant_id"], name: "index_tags_on_tenant_id"
  end

  create_table "tenants", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "name", null: false
    t.string "trade_name"
    t.string "document"
    t.string "phone"
    t.string "email"
    t.string "city"
    t.string "uf", limit: 2
    t.string "ibge_code", limit: 7
    t.string "plan", default: "free", null: false
    t.string "plan_provider", limit: 20
    t.datetime "plan_expires_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "users", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "tenant_id", null: false
    t.string "name", null: false
    t.string "email", null: false
    t.string "password_digest"
    t.string "google_uid"
    t.string "role", default: "owner", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index "lower((email)::text)", name: "index_users_on_lower_email", unique: true
    t.index ["google_uid"], name: "index_users_on_google_uid", unique: true, where: "(google_uid IS NOT NULL)"
    t.index ["tenant_id"], name: "index_users_on_tenant_id"
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "ai_usages", "tenants"
  add_foreign_key "api_tokens", "users"
  add_foreign_key "areas", "areas", column: "parent_id", on_delete: :nullify
  add_foreign_key "areas", "sites", on_delete: :cascade
  add_foreign_key "areas", "tenants"
  add_foreign_key "audit_events", "tenants", on_delete: :cascade
  add_foreign_key "device_tokens", "users"
  add_foreign_key "devices", "areas", on_delete: :nullify
  add_foreign_key "devices", "sites", on_delete: :cascade
  add_foreign_key "devices", "tenants"
  add_foreign_key "invites", "tenants"
  add_foreign_key "invites", "users", column: "accepted_by_id", on_delete: :nullify
  add_foreign_key "invites", "users", column: "created_by_id", on_delete: :nullify
  add_foreign_key "notifications", "tenants"
  add_foreign_key "notifications", "users", on_delete: :cascade
  add_foreign_key "points", "areas", on_delete: :nullify
  add_foreign_key "points", "devices", on_delete: :cascade
  add_foreign_key "points", "sites", on_delete: :cascade
  add_foreign_key "points", "tenants"
  add_foreign_key "service_api_keys", "users"
  add_foreign_key "site_memberships", "sites", on_delete: :cascade
  add_foreign_key "site_memberships", "tenants"
  add_foreign_key "site_memberships", "users", on_delete: :cascade
  add_foreign_key "sites", "tenants"
  add_foreign_key "solid_queue_batch_executions", "solid_queue_batches", column: "batch_id", on_delete: :cascade
  add_foreign_key "solid_queue_batch_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_blocked_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_claimed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_failed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_ready_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_recurring_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_scheduled_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "subscriptions", "tenants", on_delete: :cascade
  add_foreign_key "subscriptions", "users", on_delete: :nullify
  add_foreign_key "taggings", "tags", on_delete: :cascade
  add_foreign_key "taggings", "tenants"
  add_foreign_key "tags", "tenants"
  add_foreign_key "users", "tenants"
end
