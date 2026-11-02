module Notifier
  module Channels
    # Mensageiros (Pacote 4): `messenger:<id da integração>`. Toda integração
    # cujo plugin responde a `send_message(integração, notificação)` vira um
    # canal do aviso: Telegram, WhatsApp (API oficial da Meta) e o gateway
    # HTTP genérico (Evolution API, CallMeBot, ntfy...). Mensageiro novo =
    # plugin de integração com `send_message` (+ `messenger_capabilities`,
    # `webhook(integração, request)` para respostas), nada muda aqui nem no Notifier.
    #
    # Botões: cada botão leva a referência `<id do aviso>:<n.º do botão>`
    # (`ref`); quando a resposta chega (webhook ou leitura do worker) o
    # plugin chama `respond`, que grava a resposta como os botões do push
    # (uma vez só, evento `notification_action` → gatilho "Resposta de aviso").
    module Messenger
      PATTERN = /\Amessenger:(\h{8}-\h{4}-\h{4}-\h{4}-\h{12})\z/
      REF = /\A(\h{8}-\h{4}-\h{4}-\h{4}-\h{12}):(\d)\z/
      extend PluginTexts
      texts "pt-BR" => { removed: "Mensageiro removido" }, en: { removed: "Messenger removed" }, es: { removed: "Mensajero eliminado" }

      module_function

      def owns?(channel) = PATTERN.match?(channel)
      def capabilities = %i[text buttons image link]
      def messenger?(integration) = integration&.plugin.respond_to?(:send_message)

      def choices(site)
        site.integrations.order(:name).select { |i| messenger?(i) }.map { |i| [ "messenger:#{i.id}", "#{i.plugin.title}: #{i.name}" ] }
      end

      def label(channel)
        i = Integration.find_by(id: channel[PATTERN, 1])
        messenger?(i) ? "#{i.plugin.title}: #{i.name}" : text(:removed)
      end

      # Uma mensagem por aviso (o destino é a conversa da integração, não a pessoa).
      def deliver(channel, notifications)
        integration = Integration.find_by(id: channel[PATTERN, 1])
        return unless messenger?(integration)

        integration.plugin.send_message(integration, notifications.first)
      rescue Integrations::Error, SafeHttp::Error => e
        integration.error!(e)
        Rails.logger.warn("[notifier] #{channel}: #{e.message}")
      end

      # Texto comum: título, corpo e o link ao tocar.
      def text(notification)
        url = notification.open_url
        url = "#{base_url}#{url}" if url&.start_with?("/")
        [ notification.title, notification.body.presence, url ].compact.join("\n\n")
      end

      def base_url = ENV["APP_HOST"].present? ? "https://#{ENV['APP_HOST']}" : ""

      # [[ref, título]] dos botões do aviso.
      def buttons(notification) = notification.actions.each_with_index.map { |a, i| [ "#{notification.id}:#{i}", a["title"].to_s ] }

      # Imagem do aviso: [bytes, tipo] do anexo ou nil.
      def image(notification) = notification.image.attached? ? [ notification.image.download, notification.image.content_type ] : nil

      # Botão tocado no mensageiro → resposta do aviso. → :ok, :taken (já
      # respondido) ou :invalid. Quem responde: a pessoa que ligou a
      # integração, senão a dona do aviso, senão o dono da instalação.
      def respond(integration, ref)
        id, index = ref.to_s.match(REF)&.captures
        n = id && Notification.find_by(id: id, tenant_id: integration.tenant_id)
        action = n&.actions&.dig(index.to_i)
        return :invalid unless action

        user = User.find_by(id: integration.settings["user_id"], tenant_id: integration.tenant_id, disabled_at: nil) || n.user ||
               User.where(tenant_id: integration.tenant_id, role: "owner", disabled_at: nil).order(:created_at).first
        return :invalid unless user

        n.respond!(action["id"], user) ? :ok : :taken
      end

      # Corpo multipart/form-data (foto do aviso no Telegram e no WhatsApp).
      # parts: {nome → texto | [bytes, tipo, arquivo]}. → [corpo, content-type].
      def multipart(parts)
        boundary = "ma#{SecureRandom.hex(12)}"
        body = parts.map do |name, v|
          head = "--#{boundary}\r\nContent-Disposition: form-data; name=\"#{name}\""
          v.is_a?(Array) ? "#{head}; filename=\"#{v[2]}\"\r\nContent-Type: #{v[1]}\r\n\r\n#{v[0].b}\r\n" : "#{head}\r\n\r\n#{v}\r\n"
        end
        [ (body.map(&:b).join + "--#{boundary}--\r\n").b, "multipart/form-data; boundary=#{boundary}" ]
      end
    end
  end
end
