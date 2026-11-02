module Onboarding
  module Steps
    # O painel automático do local (Dashboards::Generator) com o tema escolhido
    # na galeria (Dashboards::Themes): continua automático, só ganha o tema.
    class DashboardStep < Step
      describe key: "dashboard", icon: "sparkles", art: "board"

      def self.dashboard(ctx) = Dashboard.ensure_for(ctx.site).first

      def self.locals(ctx)
        d = dashboard(ctx)
        { dashboard: d, views: d.published["views"].to_a, themes: Dashboards::Themes.plugins, current: d.published.dig("theme", "key") || "lista" }
      end

      def self.save(ctx, params)
        theme = Dashboards::Themes[params[:theme]] or return I18n.t("onboarding.dashboard.pick")
        d = dashboard(ctx)
        if d.auto?
          d.update!(definition: d.definition.to_h.merge("theme" => { "key" => theme.key }))
        else
          d.publish!(d.published.merge("theme" => d.published["theme"].to_h.merge("key" => theme.key)), author: ctx.user)
        end
        nil
      end
    end
  end
end
