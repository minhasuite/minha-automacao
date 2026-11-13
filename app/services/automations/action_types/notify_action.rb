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
      PHONE_COMMAND_KEYS = %w[tts dnd_on dnd_off silent vibrate normal volume_max volume_mute].freeze
      PHONE_COMMANDS = LocalizedLabel.for("automations.notifier.phone_commands", PHONE_COMMAND_KEYS)
      BUTTON_ID = /\A[a-z0-9_-]{1,40}\z/

      describe key: "notify", label: "Avisar", defaults: { "channels" => Notifier.default_channels, "title" => "Aviso" },
               fields: [ f("channels", :channels, "Canais", en: "Channels", es: "Canales"), f("to", :recipient, "Para", en: "To", es: "Para"),
                         f("title", :template, "Título", required: true, en: "Title", es: "Título"), f("message", :template, "Mensagem", en: "Message", es: "Mensaje"),
                         f("buttons", :buttons, "Botões (até 3, um por linha: id: Título; para comandar um ponto: id: Título -> ponto comando [valor])",
                           en: "Buttons (up to 3, one per line: id: Title; to command a point: id: Title -> point command [value])",
                           es: "Botones (hasta 3, uno por línea: id: Título; para enviar un comando a un punto: id: Título -> punto comando [valor])"),
                         f("camera", :camera, "Imagem: quadro da câmera agora", en: "Image: current camera frame", es: "Imagen: cuadro actual de la cámara"),
                         f("image_url", :template, "Ou imagem por URL (https://... ou /...)", en: "Or image by URL (https://... or /...)", es: "O imagen por URL (https://... o /...)"),
                         f("url", :template, "Ao tocar, abrir (/paineis/..., /locais/... ou https://...)", en: "On tap, open (/paineis/..., /locais/... or https://...)", es: "Al tocar, abrir (/paineis/..., /locais/... o https://...)"),
                         f("priority", :select, "Prioridade", options: Push::PRIORITIES, en: "Priority", es: "Prioridad"),
                         f("tag", :template, "Tag (substitui o aviso anterior com a mesma)", en: "Tag (replaces the previous notification with the same one)", es: "Etiqueta (reemplaza el aviso anterior con la misma)"),
                         f("merge", :duration, "Juntar avisos seguidos desta automação em um só (janela, ex.: 2m; vazio = não junta)",
                           en: "Merge back-to-back notifications from this automation into one (window, e.g. 2m; empty = never)",
                           es: "Juntar avisos seguidos de esta automatización en uno (ventana, ej.: 2m; vacío = nunca)"),
                         f("group", :text, "Grupo", en: "Group", es: "Grupo"), f("ttl", :duration, "Validade no push (ex.: 1h)", en: "Push expiration (e.g. 1h)", es: "Validez del push (ej.: 1h)"),
                         f("sticky", :bool, "Fixo (fica até tocar)", en: "Sticky (stays until tapped)", es: "Fijo (queda hasta tocarlo)"),
                         f("progress", :template, "Progresso 0–100 no app (contínuo, atualiza no lugar pela tag)", en: "Progress 0–100 in the app (ongoing, updates in place by tag)", es: "Progreso 0–100 en la app (continuo, se actualiza en el lugar por la etiqueta)"),
                         f("clear", :bool, "Só apagar o aviso com esta tag", en: "Only clear the notification with this tag", es: "Solo borrar el aviso con esta etiqueta"),
                         # appweb D2: o app executa em vez de mostrar (falar o título e a mensagem, não perturbe, campainha, volume).
                         f("phone_command", :select, "Comando no celular (app)", options: PHONE_COMMANDS, en: "Command on the phone (app)", es: "Comando en el celular (app)") ]
      texts "pt-BR" => { clear: "para apagar, informe a tag.", buttons: "botões: até %{max}, cada um com id (letras minúsculas, números, _ ou -) e título de até 40 letras.",
                         command: "botão que comanda precisa de ponto e comando.", repeated: "botões com id repetido." },
            en: { label: "Notify", clear: "to clear, enter the tag.", buttons: "buttons: up to %{max}, each with an id (lowercase letters, numbers, _ or -) and a title of up to 40 characters.",
                  command: "a button that sends a command needs a point and a command.", repeated: "buttons with a repeated id." },
            es: { label: "Avisar", clear: "para borrar, indica la etiqueta.", buttons: "botones: hasta %{max}, cada uno con id (letras minúsculas, números, _ o -) y título de hasta 40 letras.",
                  command: "un botón que envía comandos necesita punto y comando.", repeated: "botones con id repetido." }

      def self.rules(node)
        msgs = []
        msgs << text(:clear) if node["clear"] == true && node["tag"].blank?
        buttons = node["buttons"]
        if buttons && !(buttons.is_a?(Array) && buttons.size.between?(1, Notification::MAX_ACTIONS) &&
                        buttons.all? { |b| b.is_a?(Hash) && BUTTON_ID.match?(b["id"].to_s) && b["title"].to_s.strip.size.between?(1, 40) })
          msgs << text(:buttons, max: Notification::MAX_ACTIONS)
        end
        if buttons.is_a?(Array) && buttons.any? { |b| b.is_a?(Hash) && (b["command"].present? ^ b["point"].present?) }
          msgs << text(:command)
        end
        msgs << text(:repeated) if buttons.is_a?(Array) && buttons.map { |b| b.is_a?(Hash) && b["id"] }.uniq.size != buttons.size
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
          "progress" => (progress(e.ctx.render(node["progress"])) if node["progress"].present?),
          "command" => node["phone_command"].presence_in(PHONE_COMMAND_KEYS) }.compact.merge(merge_for(e, node))
      end

      # Menos ruído (só quando o bloco pede `merge`: uma automação pode mandar
      # avisos diferentes de propósito): chave = tag ou a automação; assunto =
      # nome da automação (Notifications::Merge).
      def self.merge_for(e, node)
        return {} if node["merge"].blank? || e.run.automation_id.nil?

        window = Dsl.seconds(node["merge"]).to_i
        return {} unless window.positive?

        tag = (e.ctx.render(node["tag"]).strip.presence if node["tag"])
        { "merge_key" => tag ? "tag:#{tag}" : "automation:#{e.run.automation_id}", "merge_s" => window,
          "merge_subject" => (tag ? nil : e.run.automation&.name) }.compact
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
