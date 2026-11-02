class PointSerializer < ApplicationSerializer
  EDITABLE = [ :area_id, :key, :name, :icon, :capability, :data_type, :device_class, :state_class, :unit, :min, :max, :step,
               :writable, :scale, :offset, :deadband, :history, :history_interval_s, :retention_days, :pulse_ms, :max_on_s,
               :confirm, :risk, :hidden, :disabled, { options: [], address: {}, expose: {} } ].freeze

  attributes :id, :site_id, :device_id, :area_id, :key, :name, :icon, :capability, :data_type, :device_class,
             :state_class, :unit, :options
  %i[min max step scale offset deadband].each { |f| attribute(f) { |p| decimal(p.public_send(f)) } }
  attributes :writable
  # Pacote 3: o helper esconde o que é segredo (hash do código do alarme).
  # IP, usuário, URL e afins só com `params: { reveal: true }` (técnico ou dono; Sensitive).
  attribute(:address) do |p|
    address = p.helper_type ? p.helper_type.public_address(p) : p.address
    params[:reveal] ? address : Sensitive.mask(address)
  end
  attributes :history, :history_interval_s, :retention_days, :pulse_ms, :max_on_s, :confirm,
             :risk, :expose, :helper, :value, :quality, :changed_at, :reported_at, :hidden, :disabled, :created_at, :updated_at
end
