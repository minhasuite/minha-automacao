module Updates
  # Atualizar sozinho (distribuição): o UpdateAutoJob chama `tick!` a cada 15
  # minutos. Primeiro avisa o resultado da última atualização (sozinha ou pelo
  # botão) a cada instalação; depois, com "atualizar sozinho" ligado, dentro da
  # janela e sem outra rodando, começa a atualização para a release do canal.
  # Estável só depois de AUTO_MIN_AGE publicada; uma versão que voltou ou falhou
  # não é tentada de novo sozinha (o botão continua valendo).
  module Auto
    module_function

    def tick!(now: Time.current)
      return unless Updates.supported?

      notify_result!
      start_if_due!(now)
    end

    def start_if_due!(now)
      cfg = Updates.settings
      return :off unless cfg["auto"]
      return :running if Updates.status["state"] == "running"
      return :outside unless Updates.in_window?(now)

      release = Updates.latest(force: true)
      return :none unless Updates.available?(release)
      return :failed_before if cfg["failed_tag"] == release["tag"]
      return :too_new unless old_enough?(release, now)

      Updates.start!(release["tag"])
      Updates.save_settings!("auto_started" => release["tag"], "auto_started_at" => now.iso8601)
      :started
    end

    def old_enough?(release, now)
      return true if release["prerelease"]

      at = Time.zone.parse(release["published_at"].to_s)
      at.present? && at <= now - AUTO_MIN_AGE
    rescue ArgumentError
      false
    end

    # Fim de atualização (done/rolled_back/failed) ainda não avisado → um aviso por instalação.
    def notify_result!
      st = Updates.status
      return unless %w[done rolled_back failed].include?(st["state"]) && st["at"].present?
      return if Updates.settings["notified_at"] == st["at"]

      tag = st["to"].to_s.split(":").last
      patch = { "notified_at" => st["at"] }
      patch["failed_tag"] = tag unless st["state"] == "done"
      Updates.save_settings!(patch)
      return if stale?(st["at"])

      title = I18n.t("updates.result.#{st['state']}", to: tag)
      Tenant.find_each do |tenant|
        ActsAsTenant.with_tenant(tenant) do
          Notifier.notify!(kind: "sistema", title: title, body: st["message"].presence,
                           data: { "url" => "/configuracoes/sistema", "tag" => "atualizacao" },
                           dedup_key: "atualizacao:#{tenant.id}:#{st['at']}")
        end
      end
    end

    # Resultado antigo (de antes deste aviso existir) só é marcado, sem push.
    def stale?(at)
      t = Time.zone.parse(at.to_s)
      t.nil? || t < 1.day.ago
    rescue ArgumentError
      true
    end
  end
end
