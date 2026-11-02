module Onboarding
  module Steps
    # Nome e local da casa: tipo, fuso (o do navegador vem marcado) e a
    # localização (botão do navegador ou digitada), que liga o Clima.
    class HomeStep < Step
      describe key: "home", icon: "home", art: "home"

      def self.needs_site? = false
      def self.optional? = false

      def self.locals(ctx)
        { site: ctx.site || Site.new(name: I18n.t("onboarding.home.default_name"), kind: "home"),
          weather: ctx.site.nil? || ctx.site.integrations.exists?(driver: Integrations::WeatherPlugin.driver) }
      end

      def self.save(ctx, params)
        site = ctx.site || Site.new
        site.assign_attributes(params.permit(:name, :kind, :timezone, :latitude, :longitude).to_h.transform_values(&:presence).compact)
        return site.errors.full_messages.to_sentence unless site.save

        ctx.site = site
        add_weather(site) if params[:weather] == "1"
        nil
      end

      # Clima pela localização do local (Open-Meteo, sem chave); a leitura vai para a fila.
      def self.add_weather(site)
        plugin = Integrations::WeatherPlugin
        return if site.latitude.nil? || site.longitude.nil? || site.integrations.exists?(driver: plugin.driver)

        integration = plugin.new_integration(site, name: I18n.t("onboarding.home.weather_name"), poll_s: plugin::POLL_S)
        plugin.configure(integration, {}) && integration.save! && Integrations.start_sync!(integration)
      end
    end
  end
end
