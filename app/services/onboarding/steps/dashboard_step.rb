module Onboarding
  module Steps
    # O painel automático do local (Dashboards::Generator) com o tema escolhido
    # na galeria (Dashboards::Themes): continua automático, só ganha o tema.
    # Ideia 8: com os cômodos e o estilo escolhidos (`areas`, `layout`), vira o
    # painel do assistente (`Dashboards::Wizard`: Início + uma visão
    # automática por cômodo); com todos e "por aparelho", fica o automático.
    class DashboardStep < Step
      describe key: "dashboard", icon: "sparkles", art: "board"

      def self.dashboard(ctx) = Dashboard.ensure_for(ctx.site).first

      def self.locals(ctx)
        d = dashboard(ctx)
        { dashboard: d, views: d.published["views"].to_a, themes: Dashboards::Themes.plugins, current: d.published.dig("theme", "key") || "lista",
          areas: Dashboards::Wizard.areas(ctx.site), layouts: Dashboards::Wizard.layouts }
      end

      def self.save(ctx, params)
        theme = Dashboards::Themes[params[:theme]] or return I18n.t("onboarding.dashboard.pick")
        d = dashboard(ctx)
        return wizard(ctx, d, theme, params) if wizard?(ctx, params)

        if d.auto?
          d.update!(definition: d.definition.to_h.merge("theme" => { "key" => theme.key }))
        else
          d.publish!(d.published.merge("theme" => d.published["theme"].to_h.merge("key" => theme.key)), author: ctx.user)
        end
        nil
      end

      def self.wizard?(ctx, params)
        layout = params[:layout].presence_in(Dashboards::Wizard::LAYOUTS) or return false
        layout != "devices" || Array(params[:areas]).compact_blank.sort != Dashboards::Wizard.areas(ctx.site).map(&:id).sort
      end

      def self.wizard(ctx, dashboard, theme, params)
        defn = Dashboards::Wizard.build(ctx.site, area_ids: Array(params[:areas]).compact_blank, theme: theme.key, layout: params[:layout])
        dashboard.publish!(defn, author: ctx.user)
        nil
      end
    end
  end
end
