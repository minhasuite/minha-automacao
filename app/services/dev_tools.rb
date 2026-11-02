# Ferramentas de desenvolvedor (Pacote 3; o "Ferramentas de desenvolvedor"
# do HA), só para administrador: estados, testador de Liquid/expressão,
# executar comando e eventos. As telas (web e API) chamam daqui.
module DevTools
  MAX_TEMPLATE = 4000
  STATES_LIMIT = 200

  module_function

  def admin?(user) = user&.admin?

  # Pontos do local com filtro (nome, chave, valor, capacidade).
  def states(site, q: nil, capability: nil)
    scope = site.points.includes(:device, :area).order(:key)
    scope = scope.where(capability: capability) if capability.present?
    if (q = q.to_s.squish).present?
      like = "%#{Point.sanitize_sql_like(q)}%"
      scope = scope.where("points.name ILIKE :q OR points.key ILIKE :q OR points.value::text ILIKE :q", q: like)
    end
    scope.limit(STATES_LIMIT)
  end

  def state_json(p)
    { "id" => p.id, "key" => p.key, "name" => p.name, "device" => p.device.name, "capability" => p.capability, "helper" => p.helper,
      "value" => p.value, "text" => ApplicationController.helpers.point_value_text(p), "quality" => p.quality,
      "attrs" => p.attrs.to_h, "changed_at" => p.changed_at&.iso8601, "reported_at" => p.reported_at&.iso8601 }
  end

  # Definir valor: só helper, pela regra do tipo (o painel de alarme recusa).
  def set_helper!(point, raw)
    plugin = point.helper_type or raise Points::Command::Error.new(:not_helper, "Só helper recebe valor direto; aparelho só por comando.")
    value = plugin.check(point, point.cast(raw.is_a?(String) ? raw.strip : raw))
    point.report!(value)
    point
  end

  # Liquid (padrão) ou expressão (dentaku) com o contexto do local → [resultado, erro].
  def render(site, template, mode: "liquid")
    text = template.to_s.first(MAX_TEMPLATE)
    ctx = Automations::Context.new(site: site)
    [ mode == "expr" ? ctx.calc(text) : ctx.render(text, limit: MAX_TEMPLATE), nil ]
  rescue StandardError => e # erro do Liquid, da expressão ou do contexto: vira o resultado do teste
    [ nil, e.message.truncate(300) ]
  end

  # Executar ação: comando de ponto pelo caminho normal (validação, risco no
  # controller) e respeitando a sombra do local.
  def command!(point, command, value, user:)
    Shadow.for_site(point.site) { Points::Command.call(point, command, value.presence, source: "web", user: user) }
  end

  # Disparar evento (o mesmo da ação "Disparar evento"; nome reservado não).
  def fire!(site, name, data)
    name = name.to_s.strip
    raise ArgumentError, "Nome inválido (letras minúsculas, números, _ . : -)." unless Automations::Triggers::EVENT_NAME.match?(name)
    raise ArgumentError, "\"#{name}\" é um evento do sistema." if Automations::Triggers.reserved_event?(name)

    data = data.is_a?(String) ? (data.strip.empty? ? {} : JSON.parse(data)) : data.to_h
    raise ArgumentError, "Os dados precisam ser um objeto JSON." unless data.is_a?(Hash)

    Automations::Triggers.event(site.id, name, { "data" => data, "source" => "devtools" })
    name
  rescue JSON::ParserError => e
    raise ArgumentError, "JSON inválido: #{e.message.truncate(80)}"
  end

  def stream(site_id) = "dev_events:#{site_id}"

  # Quem está com a aba Eventos aberta vê cada evento chegando (Turbo Stream).
  def broadcast(site_id, name, payload)
    WsApi.broadcast(site_id, name, payload) # ondaA2 A17: quem assinou pela API WebSocket
    html = ApplicationController.render(partial: "web/dev_tools/event", locals: { name: name, payload: payload, at: Time.current })
    Turbo::StreamsChannel.broadcast_prepend_to(stream(site_id), target: "dev-events", html: html)
  rescue StandardError => e
    Rails.logger.debug { "[dev_tools] #{e.message}" }
  end
end
