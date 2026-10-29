# Primitivas declarativas (F4, ESQUEMA-V1 §1 G4) reagindo a valor novo de
# ponto. `Point#report!` chama quando o valor muda, venha de onde vier
# (comando, aparelho físico, outro espelhamento). Cada primitiva roda isolada:
# erro numa não impede as outras nem o relato do driver.
module Automations
  # Corrente síncrona máxima (pontos virtuais se acionando em cadeia). Laço
  # entre aparelhos de verdade é barrado na validação do PointLink e pelo anti-eco.
  MAX_DEPTH = 5

  def self.on_change(point, quality_was)
    depth = Thread.current[:automations_depth].to_i
    return Rails.logger.warn("[automações] corrente longa demais em #{point.key}, parei") if depth >= MAX_DEPTH

    Thread.current[:automations_depth] = depth + 1
    # Valor que volta junto com a conexão (estava indisponível) não aciona
    # nada físico: no HA, o refresh do LocalTuya espelhava estado fantasma.
    fresh = quality_was == "good"
    safely { AutoOffJob.schedule(point) }
    safely { PointLink.propagate(point) } if fresh
    safely { NotifyRule.fire(point) } if fresh
    safely { AlertRule.evaluate(point) }
  ensure
    Thread.current[:automations_depth] = depth
  end

  def self.safely
    yield
  rescue Points::Command::Error => e
    Rails.logger.warn("[automações] #{e.message}")
  rescue StandardError => e
    Rails.error.report(e, handled: true)
  end
end
