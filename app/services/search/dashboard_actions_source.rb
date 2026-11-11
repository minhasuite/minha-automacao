module Search
  # Ações de painel no Ctrl+K (ideia 7), só para quem edita (técnico ou dono):
  # "publicar Casa" (abre a revisão com prévia e avisos), "nova visão Casa",
  # "voltar versão Casa" (comparar versões, onde fica o voltar), "desfazer
  # Casa" e "duplicar <widget>" (ações rápidas por POST no rascunho).
  class DashboardActionsSource < Source
    ACTIONS = %w[publish new_view revert undo edit_here].freeze
    MAX_WIDGETS = 400

    def self.call(q, ctx)
      return [] if q.verb

      dashboards = Dashboard.where(site_id: ctx.site_ids).ordered.select { |d| ctx.allowed?(d.site_id, :manage) && d.visible_to?(ctx.roles[d.site_id]) }
      actions(q, dashboards) + duplicates(q, dashboards)
    end

    def self.actions(q, dashboards)
      dashboards.flat_map do |d|
        ACTIONS.filter_map do |key|
          title = I18n.t("search.dashboard_actions.#{key}", name: d.name)
          words = Search.norm(I18n.t("search.dashboard_actions.#{key}_words"))
          # Precisa de uma palavra da ação ("publicar", "visão"...): só o nome do painel já sai na fonte de painéis.
          next unless match?(q, title, words) && q.terms.any? { |t| words.include?(t) }

          Result.new(kind: I18n.t("search.kinds.dashboard_action"), title: title, icon: ICONS[key], **target(key, d))
        end
      end.first(LIMIT)
    end

    ICONS = { "publish" => "upload", "new_view" => "plus", "revert" => "reply", "undo" => "reply", "edit_here" => "cursor-click" }.freeze

    def self.target(key, d)
      case key
      when "publish" then { url: review_dashboard_path(d) }
      when "new_view" then { url: edit_dashboard_path(d, nova_visao: 1) }
      when "revert" then { url: compare_dashboard_path(d) }
      when "edit_here" then { url: dashboard_path(d, editar: 1) }
      else { url: edit_dashboard_path(d), action: { label: I18n.t("search.dashboard_actions.run"), url: undo_dashboard_path(d) } }
      end
    end

    # "duplicar <nome do widget>": o widget do rascunho, copiado logo abaixo.
    def self.duplicates(q, dashboards)
      word = Search.norm(I18n.t("search.dashboard_actions.duplicate_word"))
      return [] unless q.terms.first == word && q.terms.size > 1

      rest = Query.new(text: q.text, verb: nil, terms: q.terms.drop(1))
      dashboards.flat_map do |d|
        names = Point.where(site_id: d.site_id).pluck(:id, :name).to_h
        Array(d.working_draft["views"]).flat_map do |v|
          Dashboards::Resolver.flatten(Array(v["sections"]).flat_map { |s| Array(s["widgets"]) }).first(MAX_WIDGETS).filter_map do |w|
            name = Dashboards::Diff.label(w, names)
            next unless match?(rest, name)

            Result.new(kind: I18n.t("search.kinds.dashboard_action"), title: I18n.t("search.dashboard_actions.duplicate", name: name),
                       subtitle: "#{d.name} · #{v['title']}", icon: "duplicate", url: edit_dashboard_path(d, view: v["id"], w: w["id"], anchor: w["id"]),
                       action: { label: I18n.t("search.dashboard_actions.run"), url: draft_dashboard_path(d),
                                 params: { op: "duplicate", kind: "widget", target: w["id"], view_id: v["id"] } })
          end
        end
      end.first(LIMIT)
    end
  end
end
