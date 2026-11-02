class AreaSerializer < ApplicationSerializer
  EDITABLE = %i[name kind parent_id icon background position level label_list alias_list].freeze

  attributes :id, :site_id, :parent_id, :name, :kind, :icon, :background, :position, :level, :aliases, :created_at, :updated_at
  attribute(:labels, &:label_names)
end
