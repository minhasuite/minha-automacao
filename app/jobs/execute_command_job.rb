# Executa um ::Command no driver do dispositivo: pending → sent → confirmed,
# ou failed (erro do driver) / expired (ficou na fila além do Command::TTL).
class ExecuteCommandJob < ApplicationJob
  queue_as :default

  def perform(command_id)
    command = ActsAsTenant.without_tenant { Command.find_by(id: command_id) }
    return unless command&.status == "pending"

    ActsAsTenant.with_tenant(command.tenant) { execute(command) }
  end

  private

  def execute(command)
    return command.update!(status: "expired") if command.created_at < Command::TTL.ago

    command.update!(status: "sent", sent_at: Time.current)
    point = command.point
    Drivers.for(point.device).execute(point, command.command, command.value)
    command.update!(status: "confirmed", confirmed_at: Time.current)
    settled(command)
    Integrations::DebugLog.log(point.device.integration, "comando #{point.name}: #{command.command} #{command.value.inspect} ok")
  rescue StandardError => e
    Rails.error.report(e, handled: true) unless e.is_a?(Points::Command::Error)
    command.update!(status: "failed", error: e.message.truncate(255))
    settled(command)
    Integrations::DebugLog.log(command.point&.device&.integration, "comando #{command.command} falhou: #{e.class}: #{e.message}")
  end

  # As telas abertas desenham o comando em curso ("Enviando…", Points::Inflight): ao
  # confirmar ou falhar, o quadro do ponto se refaz mesmo que o aparelho ainda não tenha avisado.
  def settled(command)
    point = command.point or return
    point.broadcast_refresh_to(point)
    Turbo::StreamsChannel.broadcast_action_to(point.site, :points, action: :point_changed, target: point.id)
  rescue StandardError => e
    Rails.error.report(e, handled: true)
  end
end
