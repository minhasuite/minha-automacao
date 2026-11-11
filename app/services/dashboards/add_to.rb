module Dashboards
  # "Adicionar ao painel" (ideia 2): da página do ponto, do aparelho, da cena,
  # da automação ou do script, o widget certo para a coisa, pela capacidade
  # (o mesmo do painel automático: `Widgets.auto_widget`/`for_capability`;
  # sem widget próprio, `tile`). Fonte nova = linha em SOURCES (o modelo e
  # como ele vira widget); nada de `case` por tipo de widget aqui.
  module AddTo
    # tipo → [modelo, lambda(registro, id do widget) → widget ou nil]
    SOURCES = {
      "point" => [ "Point", ->(p, id) { AddTo.for_point(p, id) } ],
      "device" => [ "Device", ->(d, id) { AddTo.for_device(d, id) } ],
      "scene" => [ "Scene", ->(s, id) { { "id" => id, "type" => "scene_bar", "label" => s.name, "scenes" => [ s.id ] } } ],
      # Automação: o liga/desliga dela (AutomationPoints); script: o ponto que roda (Scripts).
      "automation" => [ "Automation", ->(a, id) { AddTo.for_point(a.script? ? Scripts.point_for(a) : AutomationPoints.point_for(a), id, label: a.name) } ]
    }.freeze

    module_function

    def types = SOURCES.keys

    # O registro (no escopo da empresa atual) ou nil.
    def find(type, id)
      model, = SOURCES[type.to_s]
      model&.constantize&.find_by(id: id)
    end

    def widget(type, record)
      SOURCES.fetch(type.to_s).last.call(record, "w-#{SecureRandom.alphanumeric(8).downcase}")
    end

    def for_point(point, id, label: nil)
      return nil unless point

      w = Widgets.auto_widget(point, id) || { "id" => id, "type" => "tile", "bind" => point.id }
      w["label"] = label if label.present? && label != point.name
      w
    end

    # Aparelho: um ponto = o widget dele; vários = grupo com os que existem (até 8).
    def for_device(device, id)
      points = device.points.order(:name).select { |p| Points::Query.exists?(p) }
      return for_point(points.first, id) if points.size == 1
      return nil if points.empty?

      { "id" => id, "type" => "group", "label" => device.name, "binds" => points.first(8).map(&:id) }
    end

    # Onde pode entrar: [[painel, visão, seção]] dos painéis que a pessoa vê.
    def places(dashboards)
      dashboards.flat_map do |d|
        Array(d.working_draft["views"]).flat_map do |v|
          Array(v["sections"]).map { |s| [ d, v, s ] }
        end
      end
    end
  end
end
