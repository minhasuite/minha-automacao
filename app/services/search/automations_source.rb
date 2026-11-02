module Search
  # Automações: só para quem edita (técnico ou dono).
  class AutomationsSource < Source
    def self.call(q, ctx)
      return [] if q.verb

      sites = ctx.site_ids.select { |id| ctx.allowed?(id, :manage) }
      Automation.where(site_id: sites).order(:name).select { |a| match?(q, a.name, "automacao") }.first(LIMIT)
                .map { |a| Result.new(kind: I18n.t("search.kinds.automation"), title: a.name, subtitle: I18n.t(a.enabled ? "search.on" : "search.off"), icon: "switch-horizontal", url: edit_automation_path(a)) }
    end
  end
end
