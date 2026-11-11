# Texto de aviso escrito pela casa (P3 da proposta de personalização): a
# mensagem do Aviso (`NotifyRule#message`), o texto do Alerta
# (`AlertRule#message`) e o da verificação personalizada da Saúde
# (`CustomHealthCheck#message`). É Liquid com o mesmo contexto do Texto do
# painel e das automações (`Automations::Context`): `{{ trigger.point }}`,
# `{{ trigger.text }}`, `{{ points["sala.luz"].text }}`,
# `{{ "quality=unavailable" | points_where | size }}`, `{{ "hour * 60" | calc }}`,
# `{{ now | date: "%H:%M" }}`, `{{ site.name }}`. Sem código do usuário: só
# os filtros registrados no Context, com limite de tamanho.
#
# Os atalhos antigos `{ponto}` e `{valor}` continuam valendo (viram
# `{{ trigger.point }}` e `{{ trigger.text }}`).
module MessageTemplate
  MAX = 1000
  LEGACY = { "{ponto}" => "{{ trigger.point }}", "{valor}" => "{{ trigger.text }}" }.freeze

  module_function

  # Texto pronto (levanta Automations::Context::Error se o modelo falhar).
  def render(site, template, trigger: {}, vars: {}, limit: MAX)
    return "" if template.blank?

    Automations::Context.new(site: site, trigger: trigger, vars: vars).render(legacy(template), limit: limit).strip
  end

  # [texto, erro] para a prévia do formulário e da API.
  def preview(site, template, **)
    error = syntax_error(template) and return [ nil, error ]

    [ render(site, template, **), nil ]
  rescue Automations::Context::Error => e
    [ nil, e.message ]
  end

  # Erro de sintaxe (validação ao salvar) ou nil. Ponto que não existe só
  # aparece na prévia: o texto pode citar ponto que ainda vai nascer.
  def syntax_error(template)
    return nil if template.blank?

    Liquid::Template.parse(legacy(template), error_mode: :strict)
    nil
  rescue Liquid::Error => e
    e.message.truncate(160)
  end

  def legacy(template) = LEGACY.reduce(template.to_s) { |t, (old, new)| t.gsub(old, new) }

  # O gatilho como o texto vê: o ponto que mudou (o mesmo formato do gatilho
  # "estado" das automações, mais `key` e `text`).
  def point_trigger(point, extra = {})
    { "point_id" => point.id, "point" => point.name, "key" => point.key, "value" => point.value,
      "text" => ApplicationController.helpers.point_value_text(point) }.merge(extra.stringify_keys)
  end
end
