class SiteSerializer < ApplicationSerializer
  EDITABLE = %i[name kind timezone address latitude longitude wallpaper].freeze

  attributes :id, :name, :kind, :timezone, :address
  attribute(:latitude) { |s| decimal(s.latitude) }
  attribute(:longitude) { |s| decimal(s.longitude) }
  attributes :wallpaper
  # Papel de quem pediu (params[:user]).
  attribute(:my_role) { |s| params[:user] && s.role_for(params[:user]) }
  attributes :created_at, :updated_at
end
