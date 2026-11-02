# Tela "Expor" (ondaA1, A3; o Expor do HA): o que cada assistente vê, numa
# tela só e em massa. Assistente = alvo registrado aqui (`PLUGINS`) ou uma
# ponte de `Bridges::PLUGINS` (Matter…), sem `case` por tipo. O alvo diz:
#   key, title, icon — coluna da tela;
#   applies?(point) — o ponto serve para ele;
#   exposed?(point) — está exposto agora;
#   set!(point, on, confirm:) — expõe/tira; devolve a mensagem de erro ou nil
#     (ponto crítico só entra com `confirm`).
module Exposure
  PLUGINS = %w[Assist Alexa].freeze

  module_function

  def targets(site) = PLUGINS.map { |n| const_get(n).new(site) } + Bridges.plugins.map { |b| BridgeTarget.new(site, b) }

  class Target
    def initialize(site) = @site = site
    def applies?(_point) = true
  end

  # Voz local (Assist): exposto por padrão; tirar = `expose.assist` falso.
  class Assist < Target
    def key = "assist"
    def title = "Assist"
    def icon = "microphone"
    def exposed?(point) = point.expose.to_h["assist"] != false

    def set!(point, on, confirm: false)
      point.update!(expose: point.expose.to_h.merge("assist" => on))
      nil
    end
  end

  class Alexa < Target
    def key = "alexa"
    def title = "Alexa"
    def icon = "speakerphone"
    def applies?(point) = ::Alexa::SmartHome::Interfaces.for(point).any?
    def exposed?(point) = point.alexa_exposed

    def set!(point, on, confirm: false)
      point.assign_attributes(alexa_exposed: on, alexa_risk_confirmed: confirm)
      point.save ? nil : point.errors.full_messages.to_sentence
    end
  end

  # Ponte (Matter e as próximas): o registro BridgeExposure de sempre.
  class BridgeTarget < Target
    def initialize(site, bridge)
      super(site)
      @bridge = bridge
    end

    def key = @bridge.key
    def title = @bridge.title
    def icon = @bridge.icon
    def applies?(point) = @bridge.type_for(point).present?
    def exposed?(point) = exposed.include?(point.id)
    def exposed = @exposed ||= BridgeExposure.where(site: @site, bridge: key).pluck(:point_id).to_set

    def set!(point, on, confirm: false)
      @exposed = nil
      return BridgeExposure.where(point: point, bridge: key).destroy_all && nil unless on

      e = BridgeExposure.new(site: @site, point: point, bridge: key, risk_confirmed: confirm)
      e.save ? nil : e.errors.full_messages.to_sentence
    end
  end
end
