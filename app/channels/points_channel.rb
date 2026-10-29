# Turbo Streams de um ponto (`turbo_stream_from point, channel: PointsChannel`)
# ou dos pontos de um local nos dashboards (`turbo_stream_from site, :points`,
# só com o aviso `point_changed` e o id). Além da assinatura do nome do stream
# (Turbo), só assina quem é da empresa e tem papel no local.
class PointsChannel < Turbo::StreamsChannel
  def subscribed
    name = verified_stream_name_from_params.to_s
    gid = GlobalID.parse(name.delete_suffix(":points"))
    return reject unless gid && gid.model_name == (name.end_with?(":points") ? "Site" : "Point") && allowed?(gid)

    super
  end

  private

  def allowed?(gid)
    ActsAsTenant.with_tenant(current_user.tenant) do
      site = gid.model_name == "Site" ? Site.find_by(id: gid.model_id) : Point.find_by(id: gid.model_id)&.site
      site&.role_for(current_user).present?
    end
  end
end
