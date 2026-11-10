module Notifier
  module Channels
    # "Falar na <Echo>" (F8): `alexa:<id do ponto speaker>`. Canal de fala
    # (Lote 3): responde a `speak`, usado pela ação "Falar". Só texto: título
    # e corpo viram o anúncio (botões, imagem e link são ignorados), uma vez
    # por aviso, pelo comando `announce` na fila (como qualquer comando de
    # automação). Erro numa Echo não impede as outras nem o aviso.
    module Alexa
      PATTERN = /\Aalexa:(\h{8}-\h{4}-\h{4}-\h{4}-\h{12})\z/
      extend PluginTexts
      texts "pt-BR" => { speak_on: "Falar na %{name}", removed: "Echo removida" },
            en: { speak_on: "Speak on %{name}", removed: "Echo removed" }, es: { speak_on: "Hablar en %{name}", removed: "Echo eliminada" }

      module_function

      def owns?(channel) = PATTERN.match?(channel)
      def capabilities = %i[text]

      def choices(site)
        site.points.includes(:device).where(capability: "speaker", disabled: false).order(:name)
            .map { |p| [ "alexa:#{p.id}", text(:speak_on, name: p.device.name) ] }.sort_by(&:last)
      end

      def label(channel)
        point = Point.includes(:device).find_by(id: channel[PATTERN, 1])
        point ? text(:speak_on, name: point.device.name) : text(:removed)
      end

      # Ação "Falar" (Lote 3): só a fala, sem criar aviso. `chime` = com o som de anúncio.
      def speak(channel, text, chime: true)
        point = Point.find_by(id: channel[PATTERN, 1], capability: "speaker") or raise Points::Command::Error.new(:not_found, "Echo removida.")
        Points::Command.call(point, chime ? "announce" : "speak", text.to_s.squish.truncate(Points::Command::MAX_SPEECH), source: "automation", user: nil)
      end

      def deliver(channel, notifications) = deliver_all([ channel ], notifications)

      # Vários `alexa:<ponto>` no mesmo aviso: UM anúncio por conta da Alexa com
      # todas as Echo dela (Points::Command.call_group; docs/confiabilidade.md),
      # em vez de um pedido por Echo no mesmo segundo (a Amazon responde 429).
      def deliver_all(channels, notifications)
        n = notifications.first
        text = n.data.to_h["ssml"].presence || [ n.title, n.body ].compact_blank.join(". ")
        announce(channels, text.truncate(Points::Command::MAX_SPEECH))
      end

      def speak_all(channels, text, chime: true)
        return channels.each { |ch| speak(ch, text, chime: false) } unless chime

        announce(channels, text.to_s.squish.truncate(Points::Command::MAX_SPEECH), raise_errors: true)
      end

      # Um lote por conta (integração + cliente da Amazon); erro numa conta não impede as outras.
      def announce(channels, text, raise_errors: false)
        ids = channels.filter_map { |ch| ch[PATTERN, 1] }
        points = Point.includes(:device).where(id: ids, capability: "speaker").sort_by { |p| ids.index(p.id) }
        raise Points::Command::Error.new(:not_found, "Echo removida.") if raise_errors && points.size < ids.uniq.size

        points.group_by { |p| [ p.device.integration_id, p.device.address["customer_id"] ] }.values.map do |group|
          Points::Command.call_group(group, "announce", text, source: "automation", user: nil)
        rescue Points::Command::Error => e
          raise if raise_errors

          Rails.logger.warn("[notifier] alexa:#{group.map(&:id).join(',')}: #{e.message}")
        end
      end
    end
  end
end
