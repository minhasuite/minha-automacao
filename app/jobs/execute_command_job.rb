# Executa um ::Command no driver do dispositivo: pending → sent → confirmed,
# ou failed (erro do driver) / expired (ficou na fila além do Command::TTL).
#
# Falha passageira (docs/confiabilidade.md): quando é certo que nada chegou ao
# aparelho (`Transient.retryable?`; ponto crítico só com a conexão que nem
# abriu), o comando volta a `pending` e o job se reagenda (5 s, 30 s, 2 min ou
# o Retry-After do serviço), nunca além do `Command::TTL` contado da criação.
# `attempts` conta as tentativas; o erro de cada uma fica em `error`.
#
# Lote (`batch_id`, anúncio em várias Echo da mesma conta): o líder executa
# uma vez para todos (`execute_group` do driver) e os outros acompanham o status.
class ExecuteCommandJob < ApplicationJob
  queue_as :commands
  # Na frente de tudo na fila (Solid Queue: número menor sai antes): quem
  # apertou o interruptor está olhando para a lâmpada.
  queue_with_priority(-10)

  def perform(command_id)
    command = ActsAsTenant.without_tenant { Command.find_by(id: command_id) }
    return unless command&.status == "pending"

    ActsAsTenant.with_tenant(command.tenant) { execute(command) }
  end

  private

  def execute(command)
    return expire(command) if command.created_at < Command::TTL.ago

    command.update!(status: "sent", sent_at: Time.current, attempts: command.attempts + 1)
    follow(command)
    point = command.point
    run_driver(command, point)
    command.update!(status: "confirmed", confirmed_at: Time.current)
    settled(command)
    Integrations::DebugLog.log(point.device.integration, "comando #{point.name}: #{command.command} #{command.value.inspect} ok")
  rescue StandardError => e
    Rails.error.report(e, handled: true) unless e.is_a?(Points::Command::Error) || Transient.retryable?(e)
    return if retry_later(command, e)

    error = command.attempts > 1 ? "#{e.message} (#{command.attempts} tentativas)" : e.message
    command.update!(status: "failed", error: error.truncate(255))
    settled(command)
    Integrations::DebugLog.log(command.point&.device&.integration, "comando #{command.command} falhou: #{e.class}: #{e.message}")
  end

  def run_driver(command, point)
    driver = Drivers.for(point.device)
    others = command.followers.includes(point: :device).map(&:point)
    return driver.execute(point, command.command, command.value) if others.empty?
    return driver.execute_group([ point, *others ], command.command, command.value) if driver.respond_to?(:execute_group)

    [ point, *others ].each { |p| driver.execute(p, command.command, command.value) }
  end

  # Volta para a fila se a falha é passageira e ainda dá tempo (Command::TTL).
  def retry_later(command, error)
    return false unless command.persisted? && command.status == "sent"
    return false unless Transient.retryable?(error, strict: command.point&.risk == "critical")

    wait = Transient.wait(command.attempts, error) or return false
    return false if Time.current + wait > command.created_at + Command::TTL

    command.update!(status: "pending", error: "Tentativa #{command.attempts} falhou: #{error.message}".truncate(255))
    follow(command)
    retry_job(wait: wait)
    true
  end

  # Passou do prazo na fila. Depois de alguma tentativa é falha (com o último
  # erro); sem tentativa nenhuma, expirou como sempre.
  def expire(command)
    if command.attempts.positive?
      command.update!(status: "failed", error: "#{command.error} (prazo esgotado, sem nova tentativa)".truncate(255))
    else
      command.update!(status: "expired")
    end
    settled(command)
  end

  # Os outros do lote acompanham o líder.
  def follow(command)
    command.followers.update_all(command.attributes.slice("status", "error", "attempts", "sent_at", "confirmed_at").merge("updated_at" => Time.current)) # rubocop:disable Rails/SkipsModelValidations
  end

  # As telas abertas desenham o comando em curso ("Enviando…", Points::Inflight): ao
  # confirmar ou falhar, o quadro do ponto se refaz mesmo que o aparelho ainda não tenha avisado.
  def settled(command)
    follow(command)
    [ command.point, *command.followers.includes(:point).map(&:point) ].compact.each do |point|
      Points::Broadcast.changed(point)
    end
  rescue StandardError => e
    Rails.error.report(e, handled: true)
  end
end
