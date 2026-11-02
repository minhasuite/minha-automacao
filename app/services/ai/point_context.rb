module Ai
  # O estado da casa em texto para o prompt: os pontos escolhidos (por ponto,
  # área ou etiqueta; vazio = todos do local) com valor, qualidade, há quanto
  # tempo mudou e, com `history_s`, o resumo do histórico na janela (leituras,
  # mínimo, máximo e média dos numéricos). Genérico: serve ao "vigia de
  # anomalia", ao "resumo da semana" e ao "Perguntar à casa", que são
  # configuração do usuário. Só leitura.
  module PointContext
    MAX = 150

    module_function

    def points(site, point_ids: [], area_ids: [], tag_ids: [])
      scope = site.points.includes(:area, device: :area)
      return scope.ordered.limit(MAX).to_a if [ point_ids, area_ids, tag_ids ].all?(&:blank?)

      tagged = Tagging.where(taggable_type: "Point", tag_id: Array(tag_ids)).select(:taggable_id)
      scope.where(id: Array(point_ids)).or(scope.where(area_id: Array(area_ids)))
           .or(scope.where(area_id: nil, device_id: site.devices.where(area_id: Array(area_ids)).select(:id)))
           .or(scope.where(id: tagged)).ordered.limit(MAX).to_a
    end

    def text(ctx, history_s: nil, **refs)
      list = points(ctx.site, **refs)
      return "Nenhum ponto no contexto." if list.empty?

      stats = history_s.to_i.positive? ? history(list, ctx.now - history_s.to_i) : {}
      window = Automations::Dsl.duration_label(history_s.to_i) if stats.any?
      lines = list.map do |p|
        since = ctx.changed_at(p)
        area = p.area || p.device&.area
        parts = [ "#{p.name} [#{p.key}]#{" (#{area.name})" if area}: #{p.quality == 'good' ? ctx.point_text(p) : Automations::Dsl.qualities.fetch(p.quality, p.quality)}" ]
        parts << "mudou há #{Automations::Dsl.duration_label((ctx.now - since).to_i)}" if since
        if (count, min, max, avg = stats[p.id])
          parts << "últimas #{window}: #{count} leituras#{", mín #{num(min)}, máx #{num(max)}, média #{num(avg)}" if min}"
        end
        "- #{parts.join('; ')}"
      end
      "Estado de #{ctx.site.name} em #{I18n.l(ctx.now, format: '%d/%m/%Y %H:%M')}:\n#{lines.join("\n")}"
    end

    def history(list, from)
      Reading.where(point_id: list.map(&:id), at: from..).group(:point_id)
             .pluck(:point_id, Arel.sql("count(*)"), Arel.sql("min(value)"), Arel.sql("max(value)"), Arel.sql("avg(value)"))
             .to_h { |id, *rest| [ id, rest ] }
    end

    def num(v) = v.to_f.round(2).then { |n| n == n.to_i ? n.to_i : n }
  end
end
