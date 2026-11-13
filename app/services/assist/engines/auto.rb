module Assist
  module Engines
    # Automático (voz-offline; o "local primeiro" dos pipelines do HA): tenta
    # as contas de voz da rede da casa (provedor `local?`: Wyoming, Voz
    # local) e, se nenhuma responder, a da nuvem — só se o pipeline deixar
    # (`cloud`) e houver internet (`Internet.online?`). Sem nada que sirva:
    # erro com o motivo (o pipeline mostra e a Depuração guarda).
    class Auto < Base
      describe key: "auto", label: "Automático (local primeiro)", kinds: %i[stt tts],
               fields: [ [ "voice", :text, %i[tts] ] ],
               hint: "Usa a voz da rede da casa (Whisper/Piper) quando existe e, se ela falhar, a da nuvem (só com internet e se o pipeline deixar)."
      texts en: { label: "Automatic (local first)",
                  hint: "Uses the house network voice (Whisper/Piper) when there is one and, if it fails, the cloud one (only with internet and if the pipeline allows)." },
            es: { label: "Automático (local primero)",
                  hint: "Usa la voz de la red de la casa (Whisper/Piper) cuando existe y, si falla, la de la nube (solo con internet y si el pipeline lo permite)." }

      # Contas de voz na ordem de tentativa: locais, depois as da nuvem (padrão da instalação primeiro).
      # → [[conta, :local|:cloud]]; a nuvem só entra com `cloud` e internet.
      def self.accounts(site, kind, cloud: true)
        list = AiAccount.usable.select { |a| a.plugin.supports?(kind) }
        local, remote = list.partition { |a| a.plugin.local? }
        default = Ai::Budget.for(site.tenant).default_provider.to_s
        remote = remote.sort_by { |a| a.provider == default ? 0 : 1 }
        remote = [] unless cloud && remote.any? && Internet.online?
        local.map { |a| [ a, :local ] } + remote.map { |a| [ a, :cloud ] }
      end

      def self.transcribe(cfg, site:, audio:, media_type:, language:)
        return Installation.transcribe(cfg, site: site, audio: audio, media_type: media_type, language: language) if none?(:stt)

        attempt(cfg, site, :stt) { |acc| Assist.transcribe(site: site, audio: audio, media_type: media_type, language: language, provider: acc.provider) }
      end

      def self.speak(cfg, site:, text:, language:)
        return Installation.speak(cfg, site: site, text: text, language: language) if none?(:tts)

        attempt(cfg, site, :tts) do |acc|
          voice = cfg["voice"].presence if acc.plugin.local?
          Ai::Audio.speak(tenant: site.tenant, site: site, text: text, voice: voice, provider: acc.provider, source: "voz").data
        end
      end

      # Nenhuma conta de voz na instalação: o caminho de sempre (a IA da instalação diz o que falta).
      def self.none?(kind) = AiAccount.usable.none? { |a| a.plugin.supports?(kind) }

      # Cada conta até uma responder; quem respondeu fica em `Assist::Engines.used` (a etapa da Depuração mostra).
      def self.attempt(cfg, site, kind)
        list = accounts(site, kind, cloud: cfg.fetch("cloud", true) != false)
        raise Ai::Client::Error, I18n.t("assist.offline.no_#{kind}") if list.empty?

        errors = []
        list.each do |acc, where|
          result = yield(acc)
          Engines.used = { "provider" => acc.provider, "where" => where.to_s }
          return result
        rescue Ai::Client::Error => e
          errors << "#{acc.provider}: #{e.message.truncate(80)}"
        end
        raise Ai::Client::Error, errors.join(" · ")
      end
    end
  end
end
