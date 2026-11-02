module Search
  # Automações: só para quem edita (técnico ou dono).
  class AutomationsSource < Source
    def self.call(q, ctx)
      return [] if q.verb

      sites = ctx.site_ids.select { |id| ctx.allowed?(id, :manage) }
      Automation.where(site_id: sites).order(:name).select { |a| match?(q, a.name, "automacao") }.first(LIMIT)
                .map { |a| Result.new(kind: "Automação", title: a.name, subtitle: (a.enabled ? "Ligada" : "Desligada"), icon: "switch-horizontal", url: edit_automation_path(a)) }
    end
  end
end
