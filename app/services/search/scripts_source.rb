module Search
  # Scripts: "executar script Boa noite" (ou só o nome) roda, se está publicado, não pede
  # campo obrigatório e o papel comanda o risco dele (crítico com a confirmação que a tela
  # do script também pede). Com campos, abre o formulário de executar.
  class ScriptsSource < Source
    def self.prefix = "script"

    def self.call(q, ctx)
      return [] if q.verb && q.verb != "activate"

      list = scope(ctx).select { |s| match?(q, s.name, s.description, "script") }.first(CANDIDATES).map { |s| build(s, ctx) }
      q.verb ? list.select(&:action) : list
    end

    def self.lookup(id, ctx) = (s = scope(ctx).find_by(id: id)) && build(s, ctx)
    def self.scope(ctx) = Automation.where(kind: "script", site_id: ctx.site_ids).order(:name)

    def self.build(s, ctx)
      action = api = nil
      if s.published? && Array(s.fields).none? { |f| f["required"] }
        risk = s.max_risk(s.definition)
        if ctx.allowed?(s.site_id, :command, risk: risk)
          critical = risk == "critical"
          label = I18n.t("search.run")
          action = { label: label, url: run_automation_path(s), params: ({ confirm_critical: 1 } if critical),
                     confirm: (I18n.t("search.run_script", name: s.name) if risk != "normal"), confirm_title: (Point::RISKS[risk] if risk != "normal") }.compact
          api = { path: "/scripts/#{s.id}/run", body: critical ? { confirm_critical: true } : {} }
        end
      end
      url = ctx.allowed?(s.site_id, :manage) ? edit_automation_path(s) : run_automation_path(s)
      Result.new(kind: I18n.t("search.kinds.script"), title: s.name, subtitle: s.description.presence&.truncate(80), icon: s.icon.presence || "play",
                 url: url, action: action, api: api, key: "#{prefix}:#{s.id}")
    end
  end
end
