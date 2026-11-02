class SiteSerializer < ApplicationSerializer
  EDITABLE = %i[name kind timezone address latitude longitude wallpaper unit_system currency elevation country language].freeze

  attributes :id, :name, :kind, :timezone, :address
  attribute(:latitude) { |s| decimal(s.latitude) }
  attribute(:longitude) { |s| decimal(s.longitude) }
  attributes :wallpaper, :unit_system, :currency, :elevation, :country, :language
  # Papel de quem pediu (params[:user]).
  attribute(:my_role) { |s| params[:user] && s.role_for(params[:user]) }
  # Tempo real do app (F7): nome assinado do stream `[site, :points]` para
  # assinar o PointsChannel pelo /cable (chega `point_changed` com o id).
  attribute(:points_stream) { |s| Turbo::StreamsChannel.signed_stream_name([ s, :points ]) }
  attributes :created_at, :updated_at
end
