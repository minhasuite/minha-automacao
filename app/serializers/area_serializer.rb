class AreaSerializer < ApplicationSerializer
  EDITABLE = %i[name kind parent_id icon background position].freeze

  attributes :id, :site_id, :parent_id, :name, :kind, :icon, :background, :position, :created_at, :updated_at
end
