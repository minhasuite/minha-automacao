module Dashboards
  # Validação ao publicar (ideia 25): avisos que NÃO bloqueiam a publicação
  # (o Schema já barrou o que quebra), com o widget e a visão para o link
  # "corrigir". Genérico, pela chave e não pelo tipo do widget:
  #
  # - ponto citado (`bind`, `binds`, `point`, `points`, `*_point(s)`, em qualquer
  #   nível: visible_if, style_if, gestos...) que não existe no local;
  # - ponto desativado, ou de aparelho removido da conta / desativado;
  # - ponto "bom" sem leitura há SILENT_DAYS dias ou mais, ou sem sinal há tanto tempo;
  # - `query` que hoje não devolve ponto nenhum (ou que nem é uma consulta válida);
  # - `area` / `scenes` que não existem mais;
  # - visão só para algumas telas (`visible_if.screen`): a inicial que some numa tela e a tela sem aba.
  #
  #   Lint.call(site, definition) → [{ "view_id", "view_title", "widget_id", "label", "kind", "text" }]
  module Lint
    SILENT_DAYS = 3
    POINT_KEY = /\A(bind|binds|point|points|\w+_points?)\z/
    MAX = 100

    module_function

    def call(site, definition, now: Time.current)
      ctx = { site: site, now: now, points: site.points.includes(:device).to_a, areas: site.areas.pluck(:id).to_set,
              scenes: site.scenes.pluck(:id).to_set }
      ctx[:by_id] = ctx[:points].index_by(&:id)
      ctx[:by_key] = ctx[:points].index_by(&:key)
      ctx[:names] = ctx[:points].to_h { |p| [ p.id, p.name ] }
      out = []
      Array(definition.to_h["views"]).each do |view|
        next unless view.is_a?(Hash)

        Array(view["sections"]).each do |s|
          walk(Array(s.is_a?(Hash) ? s["widgets"] : nil), view, ctx, out)
        end
        walk(Array(view["badges"]), view, ctx, out)
      end
      views(definition.to_h, out)
      out.uniq.first(MAX)
    end

    # visao-entrega: `visible_if.screen` das visões. A inicial que some numa tela (lá abre outra) e a
    # tela sem nenhuma aba (lá a visão aberta aparece mesmo assim).
    def views(definition, out)
      list = Array(definition["views"]).select { |v| v.is_a?(Hash) && v["subview"] != true }
      start = list.find { |v| v["id"] == definition["start_view"] }
      if start && (screens = Dashboards.view_screens(start)).any?
        out << view_row(start, "view_start_screen", screens: screens.map { |s| I18n.t("dashboards.screens.#{s}") }.join(", "))
      end
      return unless list.any? { |v| Dashboards.view_screens(v).any? }

      Schema::SCREENS.each do |screen|
        next if list.any? { |v| Dashboards.view_shown_on?(v, screen) }

        out << view_row(list.first, "view_no_screen", screen: I18n.t("dashboards.screens.#{screen}"))
      end
    end

    def view_row(view, kind, **vars)
      { "view_id" => view["id"], "view_title" => view["title"], "widget_id" => nil, "label" => view["title"], "kind" => kind,
        "text" => I18n.t("dashboards.lint.#{kind}", **vars) }
    end

    def walk(list, view, ctx, out)
      list.each do |w|
        next unless w.is_a?(Hash)

        widget(w, ctx).each do |kind, vars|
          out << { "view_id" => view["id"], "view_title" => view["title"], "widget_id" => w["id"], "label" => Diff.label(w, ctx[:names]), "kind" => kind,
                   "text" => I18n.t("dashboards.lint.#{kind}", **vars) }
        end
        walk(Array(w["widgets"]), view, ctx, out) if w["widgets"].is_a?(Array)
      end
    end

    # [[tipo do aviso, variáveis do texto]]
    def widget(w, ctx)
      found = []
      refs(w.except("widgets")).uniq.each do |ref|
        p = ctx[:by_id][ref] || ctx[:by_key][ref]
        found << (p ? point(p, ctx) : [ "missing_point", { ref: ref.truncate(40) } ])
      end
      found << [ "missing_area", {} ] if w["area"].is_a?(String) && w["area"].present? && !ctx[:areas].include?(w["area"])
      found << [ "missing_scene", {} ] if (Array(w["scenes"]).grep(String) - ctx[:scenes].to_a).any?
      found << query(w["query"], ctx) if w["query"].is_a?(Hash)
      found.compact
    end

    def point(p, ctx)
      d = p.device
      return [ "device_removed", { name: p.name, device: d.name } ] if d&.removed_at
      return [ "device_disabled", { name: p.name, device: d.name } ] if d&.disabled
      return [ "point_disabled", { name: p.name } ] if p.disabled

      at = p.reported_at || p.changed_at
      return unless at && at < ctx[:now] - SILENT_DAYS.days

      [ "silent", { name: p.name, days: ((ctx[:now] - at) / 1.day).floor } ]
    end

    def query(q, ctx)
      return if Points::Query.new(ctx[:site], points: ctx[:points], now: ctx[:now]).call(q, with_state: false).any?

      [ "empty_query", {} ]
    rescue ArgumentError => e
      [ "bad_query", { error: e.message.truncate(120) } ]
    end

    # Os ids/chaves de ponto citados em qualquer nível do widget.
    def refs(node, key = nil)
      case node
      when Hash then node.flat_map { |k, v| refs(v, k.to_s) }
      when Array then node.flat_map { |v| refs(v, key) }
      when String then key&.match?(POINT_KEY) && node.present? ? [ node ] : []
      else []
      end
    end
  end
end
