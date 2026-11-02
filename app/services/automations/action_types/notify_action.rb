module Automations
  module ActionTypes
    # "Avisar": notificação in-app, push nos aparelhos inscritos (PWA e app) e
    # fala na Echo. Lote 1: destinatário (administradores, uma pessoa ou um
    # papel no local), até 3 botões (a resposta vira o evento
    # "notification_action": gatilho "Resposta de aviso" ou a ação "Esperar
    # resposta do aviso"), imagem (quadro da câmera capturado agora ou URL),
    # link ao tocar e as opções de push: prioridade, tag (substitui o anterior),
    # validade, fixo e grupo. "Só apagar" tira o aviso com a tag.
    class NotifyAction < Base
      BUTTON_ID = /\A[a-z0-9_-]{1,40}\z/

      describe key: "notify", label: "Avisar", defaults: { "channels" => Notifier.default_channels, "title" => "Aviso" },
               fields: [ f("channels", :channels, "Canais"), f("to", :recipient, "Para"), f("title", :template, "Título", required: true),
                         f("message", :template, "Mensagem"), f("buttons", :buttons, "Botões (até 3, um por linha: id: Título; para comandar um ponto: id: Título -> ponto comando [valor])"),
                         f("camera", :camera, "Imagem: quadro da câmera agora"), f("image_url", :template, "Ou imagem por URL (https://... ou /...)"),
                         f("url", :template, "Ao tocar, abrir (/paineis/..., /locais/... ou https://...)"),
                         f("priority", :select, "Prioridade", options: Push::PRIORITIES), f("tag", :template, "Tag (substitui o aviso anterior com a mesma)"),
                         f("group", :text, "Grupo"), f("ttl", :duration, "Validade no push (ex.: 1h)"), f("sticky", :bool, "Fixo (fica até tocar)"),
                         f("progress", :template, "Progresso 0–100 no app (contínuo, atualiza no lugar pela tag)"),
                         f("clear", :bool, "Só apagar o aviso com esta tag") ]

      def self.rules(node)
        msgs = []
        msgs << "para apagar, informe a tag." if node["clear"] == true && node["tag"].blank?
        buttons = node["buttons"]
        if buttons && !(buttons.is_a?(Array) && buttons.size.between?(1, Notification::MAX_ACTIONS) &&
                        buttons.all? { |b| b.is_a?(Hash) && BUTTON_ID.match?(b["id"].to_s) && b["title"].to_s.strip.size.between?(1, 40) })
          msgs << "botões: até #{Notification::MAX_ACTIONS}, cada um com id (letras minúsculas, números, _ ou -) e título de até 40 letras."
        end
        if buttons.is_a?(Array) && buttons.any? { |b| b.is_a?(Hash) && (b["command"].present? ^ b["point"].present?) }
          msgs << "botão que comanda precisa de ponto e comando."
        end
        msgs << "botões com id repetido." if buttons.is_a?(Array) && buttons.map { |b| b.is_a?(Hash) && b["id"] }.uniq.size != buttons.size
        msgs
      end

      def self.call(e, _path, node)
        title = e.ctx.render(node["title"])
        body = e.ctx.render(node["message"]).presence
        channels = node["channels"].presence || Notifier.default_channels
        data = data_for(e, node)
        detail = [ body, "canais: #{channels.map { |ch| Notifier.channel_label(ch) }.join(', ').downcase}",
                   ("botões: #{data['actions'].pluck('title').join(', ')}" if data["actions"]), ("abre #{data['url']}" if data["url"]) ].compact.join(" · ")
        if node["clear"] == true
          label = "Apagar aviso #{data['tag']}"
          return [ label, "simulated", "Não apagado (simulação)." ] if e.dry_run?

          Notifier.deliver!(channels, to: node["to"].presence || "admins", site: e.ctx.site, clear: true, kind: "automacao", title: title, data: data)
          return [ label, "ok" ]
        end
        return [ "Avisar: #{title}", "simulated", "Não enviado (simulação). #{detail}" ] if e.dry_run?

        image, note = camera_image(e, node)
        Notifier.deliver!(channels, to: node["to"].presence || "admins", site: e.ctx.site, kind: "automacao", title: title, body: body, data: data, image: image)
        [ "Avisar: #{title}", "ok", [ detail, note ].compact.join(" · ") ]
      end

      def self.data_for(e, node)
        r = e.run
        { "automation_id" => r.automation_id, "run_id" => r.id, "site_id" => r.site_id, "actions" => buttons(e, node["buttons"]),
          "url" => (e.ctx.render(node["url"]).strip.presence if node["url"]), "image_url" => (e.ctx.render(node["image_url"]).strip.presence if node["image_url"]),
          "tag" => (e.ctx.render(node["tag"]).strip.presence if node["tag"]), "priority" => node["priority"], "group" => node["group"].presence,
          "ttl" => (Dsl.seconds(node["ttl"]) if node["ttl"]), "sticky" => (true if node["sticky"] == true),
          "progress" => (progress(e.ctx.render(node["progress"])) if node["progress"].present?) }.compact
      end

      # Botão com `point` (chave ou id) e `command`: leva o id do ponto (Notification#run_command).
      def self.buttons(e, list)
        Array(list).map do |b|
          point = b["point"].presence && e.ctx.point(b["point"])
          point ? b.except("point").merge("point_id" => point.id) : b.except("point", "command", "value")
        end.presence
      end

      # "42", "42.7", "120" → 0..100 (texto que não é número = sem barra).
      def self.progress(text)
        n = Float(text.to_s.strip.tr(",", "."), exception: false)
        n&.round&.clamp(0, 100)
      end

      # Quadro da câmera capturado agora e guardado (expira com o aviso). Câmera
      # fora do ar não impede o aviso: sai sem imagem e o trace diz.
      def self.camera_image(e, node)
        return unless node["camera"]

        point = e.ctx.point(node["camera"]) or return [ nil, "câmera removida" ]
        jpeg = Integrations.snapshot(point) || Drivers::Go2rtc.snapshot(point) # integ: detecção com IA traz o quadro do plugin
        [ ActiveStorage::Blob.create_and_upload!(io: StringIO.new(jpeg), filename: "#{point.key}-#{Time.current.to_i}.jpg", content_type: "image/jpeg"), "com quadro de #{point.name}" ]
      rescue Drivers::Go2rtc::Error, Integrations::Error => ex
        [ nil, "sem imagem: #{ex.message}" ]
      end
    end
  end
end
