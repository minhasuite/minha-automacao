class AreaSerializer < ApplicationSerializer
  EDITABLE = %i[name kind parent_id icon background position level].freeze

  attributes :id, :site_id, :parent_id, :name, :kind, :icon, :background, :position, :level, :created_at, :updated_at
end
