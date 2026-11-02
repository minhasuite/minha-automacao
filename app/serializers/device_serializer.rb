class DeviceSerializer < ApplicationSerializer
  EDITABLE = [ :area_id, :driver, :name, :manufacturer, :model, :serial, :external_id, :firmware, :battery_point_id, :disabled, :listen, :poll_s, { address: {} } ].freeze

  attributes :id, :site_id, :area_id, :driver, :name, :manufacturer, :model, :external_id
  # IP, usuário, MAC e afins só com `params: { reveal: true }` (técnico ou dono; Sensitive).
  attribute(:serial) { |d| params[:reveal] || d.serial.nil? ? d.serial : Sensitive::MASK }
  attribute(:address) { |d| params[:reveal] ? d.address : Sensitive.mask(d.address) }
  attributes :firmware, :status, :last_seen_at, :battery_point_id, :disabled, :listen, :poll_s, :polled_at, :created_at, :updated_at
end
