module Notifier
  module Channels
    # "Falar no <player>" (ondaC2, C9; o tts.speak do HA): canal de fala para
    # todo ponto que toca endereço (`play_media`): Chromecast, Sonos, DLNA,
    # TVs, grupo de players e câmera com alto-falante. A fala sai do provedor
    # de voz da instalação (Ai::Audio), vira anexo com URL assinada e o player
    # toca pela rede de casa (`MediaSources.public_url`).
    module Player
      PATTERN = /\Aplayer:(\h{8}-\h{4}-\h{4}-\h{4}-\h{12})\z/
      CAPS = %w[media stream].freeze
      extend PluginTexts
      texts "pt-BR" => { speak_on: "Falar em %{name}", removed: "Player removido" },
            en: { speak_on: "Speak on %{name}", removed: "Player removed" }, es: { speak_on: "Hablar en %{name}", removed: "Reproductor eliminado" }

      module_function

      # Horário de silêncio (Notifications): :person = o de cada pessoa; :house = o da casa.
      def quiet_scope = :house

      def owns?(channel) = PATTERN.match?(channel)
      def capabilities = %i[text]

      def players(site)
        site.points.includes(:device).where(capability: CAPS, disabled: false, writable: true).order(:name)
            .select { |p| Points::Command.commands_for(p).include?("play_media") }
      end

      def choices(site) = players(site).map { |p| [ "player:#{p.id}", text(:speak_on, name: name(p)) ] }.sort_by(&:last)
      def name(point) = point.helper.present? ? point.name : "#{point.device.name}#{" · #{point.name}" if point.capability == 'stream'}"

      def label(channel)
        point = Point.includes(:device).find_by(id: channel[PATTERN, 1])
        point ? text(:speak_on, name: name(point)) : text(:removed)
      end

      def speak(channel, text, chime: true) # rubocop:disable Lint/UnusedMethodArgument
        point = Point.find_by(id: channel[PATTERN, 1]) or raise Points::Command::Error.new(:not_found, text(:removed))
        Points::Command.call(point, "play_media", MediaSources.speech_url(point.site, text), source: "automation", user: nil)
      rescue Ai::Client::Error => e
        raise Points::Command::Error.new(:tts_failed, e.message)
      end

      def deliver(channel, notifications)
        n = notifications.first
        speak(channel, [ n.title, n.body ].compact_blank.join(". "))
      rescue Points::Command::Error => e
        Rails.logger.warn("[notifier] #{channel}: #{e.message}")
      end
    end
  end
end
