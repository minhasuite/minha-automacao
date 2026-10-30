module Points
  # Últimos acontecimentos de um ponto para a tela: comandos (quem, de onde,
  # como terminou), eventos (qualidade) e mudanças de cadastro (auditoria).
  class Timeline
    Item = Struct.new(:at, :kind, :title, :detail, :user, :tone, keyword_init: true)
    COMMAND_LABELS = { "on" => "Ligar", "off" => "Desligar", "toggle" => "Alternar", "set" => "Ajustar",
                       "select" => "Selecionar", "press" => "Acionar", "pulse" => "Acionar", "start" => "Iniciar limpeza",
                       "pause" => "Pausar", "stop" => "Parar", "home" => "Voltar à base", "clean_rooms" => "Limpar cômodos",
                       "wash_mop" => "Lavar o pano", "dry_mop" => "Secar o pano", "empty" => "Esvaziar", "locate" => "Localizar",
                       "announce" => "Anunciar", "speak" => "Falar", "increment" => "Incrementar", "decrement" => "Decrementar",
                       "reset" => "Zerar", "cancel" => "Cancelar", "finish" => "Terminar", "run" => "Executar" }.freeze
    QUALITY_LABELS = { "good" => "Normal", "stale" => "Desatualizado", "unavailable" => "Indisponível", "error" => "Com erro" }.freeze
    AUDIT_LABELS = { "create" => "Ponto criado", "update" => "Cadastro alterado", "destroy" => "Ponto excluído" }.freeze
    TONES = { "confirmed" => "success", "failed" => "danger", "expired" => "warn" }.freeze

    def self.call(point, limit: 20) = new(point, limit).call

    def initialize(point, limit)
      @point = point
      @limit = limit
    end

    def call
      commands = @point.commands.recent.limit(@limit).to_a
      events = @point.events.recent.limit(@limit).to_a
      audits = AuditEvent.where(auditable_type: "Point", auditable_id: @point.id).order(created_at: :desc).limit(@limit).to_a
      users = User.where(id: (commands.map(&:user_id) + audits.map(&:user_id)).compact.uniq).index_by(&:id)

      items = commands.map { |c| command_item(c, users[c.user_id]) } +
              events.map { |e| event_item(e) } +
              audits.map { |a| audit_item(a, users[a.user_id]) }
      items.sort_by { |i| -i.at.to_f }.first(@limit)
    end

    private

    def command_item(c, user)
      label = COMMAND_LABELS.fetch(c.command, c.command)
      label = "#{label} #{c.value}" if c.value.present?
      Item.new(at: c.created_at, kind: "command", title: label, user: user&.name,
               detail: [ "pelo #{c.source_label}", c.status_label.downcase, c.error ].compact.join(" · "),
               tone: TONES.fetch(c.status, "muted"))
    end

    def event_item(e)
      to = e.payload["to"]
      Item.new(at: e.at, kind: "event", title: "Ficou #{QUALITY_LABELS.fetch(to, to).downcase}",
               detail: "antes: #{QUALITY_LABELS.fetch(e.payload['from'], e.payload['from']).downcase}",
               tone: to == "good" ? "success" : "warn")
    end

    def audit_item(a, user)
      Item.new(at: a.created_at, kind: "audit", title: AUDIT_LABELS.fetch(a.action, a.action), user: user&.name,
               detail: a.details.keys.map { |k| Point.human_attribute_name(k).downcase }.join(", ").presence, tone: "muted")
    end
  end
end
