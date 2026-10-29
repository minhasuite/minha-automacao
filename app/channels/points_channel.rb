# Turbo Streams de um ponto (`turbo_stream_from point, channel: PointsChannel`).
# Além da assinatura do nome do stream (Turbo), só assina quem é da empresa
# do ponto e tem papel no local dele.
class PointsChannel < Turbo::StreamsChannel
  def subscribed
    gid = GlobalID.parse(verified_stream_name_from_params.to_s)
    return reject unless gid&.model_name == "Point" && allowed?(gid.model_id)

    super
  end

  private

  def allowed?(point_id)
    ActsAsTenant.with_tenant(current_user.tenant) { Point.find_by(id: point_id)&.site&.role_for(current_user).present? }
  end
end
