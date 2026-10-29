# `pulse_ms` (portão: liga e desliga sozinho) e `max_on_s` (filtro da piscina:
# desliga depois de X). Agendado no banco (Solid Queue), então sobrevive a
# reinício do servidor; vale para o ponto ligado por qualquer caminho (tela,
# app, aparelho físico, espelhamento). O carimbo `changed_at` dispensa
# cancelar: se o ponto desligou e religou, o job antigo não age e o novo conta.
class AutoOffJob < ApplicationJob
  queue_as :default

  def self.schedule(point)
    return unless point.value == true

    delay = [ point.pulse_ms && (point.pulse_ms / 1000.0), point.max_on_s ].compact.min or return
    set(wait: delay.seconds).perform_later(point.id, point.changed_at.iso8601(6))
  end

  def perform(point_id, changed_at)
    point = ActsAsTenant.without_tenant { Point.find_by(id: point_id) } or return
    ActsAsTenant.with_tenant(point.tenant) do
      next unless point.value == true && point.changed_at&.iso8601(6) == changed_at

      Points::Command.call(point, "off", source: "automation", user: nil)
    end
  end
end
