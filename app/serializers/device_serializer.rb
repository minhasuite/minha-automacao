class DeviceSerializer < ApplicationSerializer
  EDITABLE = [ :area_id, :driver, :name, :manufacturer, :model, :serial, :external_id, :firmware, :battery_point_id, :disabled, :listen, :poll_s, { address: {} } ].freeze

  attributes :id, :site_id, :area_id, :driver, :name, :manufacturer, :model, :serial, :external_id, :address,
             :firmware, :status, :last_seen_at, :battery_point_id, :disabled, :listen, :poll_s, :polled_at, :created_at, :updated_at
end
