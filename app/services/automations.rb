# Primitivas declarativas (F4, ESQUEMA-V1 §1 G4) e automações da DSL (F6,
# Automations::Triggers) reagindo a valor novo de ponto. `Point#report!` chama
# quando o valor muda, venha de onde vier (comando, aparelho físico, outro
# espelhamento). Cada primitiva roda isolada:
# erro numa não impede as outras nem o relato do driver.
module Automations
  # Corrente síncrona máxima (pontos virtuais se acionando em cadeia). Laço
  # entre aparelhos de verdade é barrado na validação do PointLink e pelo anti-eco.
  MAX_DEPTH = 5

  def self.on_change(point, quality_was, value_was = nil)
    depth = Thread.current[:automations_depth].to_i
    return Rails.logger.warn("[automações] corrente longa demais em #{point.key}, parei") if depth >= MAX_DEPTH

    Thread.current[:automations_depth] = depth + 1
    Shadow.for_site(point.site) { primitives(point, fresh(quality_was), value_was) }
  ensure
    Thread.current[:automations_depth] = depth
  end

  # Valor que volta junto com a conexão (estava indisponível) não aciona
  # nada físico: no HA, o refresh do LocalTuya espelhava estado fantasma.
  def self.fresh(quality_was) = quality_was == "good"

  # Local em sombra (F10): tudo aqui roda marcado (comando e aviso segurados).
  def self.primitives(point, fresh, value_was)
    safely { AutoOffJob.schedule(point) }
    safely { PointLink.propagate(point) } if fresh
    safely { NotifyRule.fire(point) } if fresh
    safely { AlertRule.evaluate(point) }
    # Helpers calculados que dependem do ponto (grupo, sensor calculado, estatística).
    safely { HelperTypes.on_change(point) }
    # Automações da DSL (F6).
    safely { Triggers.on_change(point, value_was, fresh: fresh) }
  end

  def self.safely
    yield
  rescue Points::Command::Error => e
    Rails.logger.warn("[automações] #{e.message}")
  rescue StandardError => e
    Rails.error.report(e, handled: true)
  end
end
