module Notifier
  module Channels
    # "Falar na <Echo>" (F8): `alexa:<id do ponto speaker>`. Canal de fala
    # (Lote 3): responde a `speak`, usado pela ação "Falar". Só texto: título
    # e corpo viram o anúncio (botões, imagem e link são ignorados), uma vez
    # por aviso, pelo comando `announce` na fila (como qualquer comando de
    # automação). Erro numa Echo não impede as outras nem o aviso.
    module Alexa
      PATTERN = /\Aalexa:(\h{8}-\h{4}-\h{4}-\h{4}-\h{12})\z/

      module_function

      def owns?(channel) = PATTERN.match?(channel)
      def capabilities = %i[text]

      def choices(site)
        site.points.includes(:device).where(capability: "speaker", disabled: false).order(:name)
            .map { |p| [ "alexa:#{p.id}", "Falar na #{p.device.name}" ] }.sort_by(&:last)
      end

      def label(channel)
        point = Point.includes(:device).find_by(id: channel[PATTERN, 1])
        point ? "Falar na #{point.device.name}" : "Echo removida"
      end

      # Ação "Falar" (Lote 3): só a fala, sem criar aviso. `chime` = com o som de anúncio.
      def speak(channel, text, chime: true)
        point = Point.find_by(id: channel[PATTERN, 1], capability: "speaker") or raise Points::Command::Error.new(:not_found, "Echo removida.")
        Points::Command.call(point, chime ? "announce" : "speak", text.to_s.squish.truncate(Points::Command::MAX_SPEECH), source: "automation", user: nil)
      end

      def deliver(channel, notifications)
        n = notifications.first
        point = Point.find_by(id: channel[PATTERN, 1], capability: "speaker") or return
        text = [ n.title, n.body ].compact_blank.join(". ")
        Points::Command.call(point, "announce", text.truncate(Points::Command::MAX_SPEECH), source: "automation", user: nil)
      rescue Points::Command::Error => e
        Rails.logger.warn("[notifier] #{channel}: #{e.message}")
      end
    end
  end
end
