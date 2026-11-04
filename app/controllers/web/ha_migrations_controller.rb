module Web
  # "Migre do HA em 10 minutos": conectar (URL + token), revisar e escolher,
  # importar com progresso e conferir o relatório. Tudo entra em modo sombra
  # (nada comanda até a pessoa tirar). Técnico ou dono.
  class HaMigrationsController < ApplicationController
    before_action :load_site

    def show
      @integration = Integrations::HaMigration.integration(@site)
      @state = Integrations::HaMigration.state(@integration)
    end

    def connect
      plugin = Integrations::HomeAssistantPlugin
      integration = Integrations::HaMigration.integration(@site) || plugin.new_integration(@site, name: plugin.title, poll_s: 0)
      return back_to_form(t("ha_migration.flash.missing")) unless plugin.configure(integration, params)

      integration.save!
      plugin.get(integration, "/api/") # testa na hora: endereço bloqueado ou token recusado voltam já
      integration.ok!
      Integrations::HaMigration.save_state!(integration, { "status" => "fetching", "started_at" => Time.current.iso8601 })
      HaMigrationJob.perform_later(integration.id, "fetch")
      redirect_to site_ha_migration_path(@site)
    rescue Integrations::Error => e
      integration&.error!(e) if integration&.persisted?
      back_to_form(t("ha_migration.flash.no_answer", error: e.message))
    end

    def import
      integration = Integrations::HaMigration.integration(@site) or return redirect_to(site_ha_migration_path(@site))
      choice = { "helpers" => params[:helpers] == "1" }.merge(%w[automations scripts scenes].to_h { |k| [ k, Array(params[k]).compact_blank.first(500) ] })
      templates = Integrations::HaMigration.templates_from(params[:config_yaml])
      state = Integrations::HaMigration.state(integration)
      Integrations::HaMigration.save_state!(integration, state.merge("status" => "importing", "choice" => choice.merge("templates" => templates.size),
                                                                    "progress" => nil, "error" => nil))
      HaMigrationJob.perform_later(integration.id, "import", choice.merge("templates" => templates)) # o arquivo não fica guardado
      redirect_to site_ha_migration_path(@site)
    end

    # Painéis do HA (Integrations::HaDashboards): importa ou reimporta todos, à parte das automações.
    def dashboards
      integration = Integrations::HaMigration.integration(@site) or return redirect_to(site_ha_migration_path(@site))
      state = Integrations::HaMigration.state(integration)
      Integrations::HaMigration.save_state!(integration, state.merge("dashboards" => { "status" => "running", "started_at" => Time.current.iso8601 }))
      HaMigrationJob.perform_later(integration.id, "dashboards")
      redirect_to site_ha_migration_path(@site, anchor: "mg-dash")
    end

    def reset
      integration = Integrations::HaMigration.integration(@site)
      Integrations::HaMigration.save_state!(integration, {}) if integration
      redirect_to site_ha_migration_path(@site)
    end

    private

    def load_site
      @site = Site.find(params[:site_id])
      authorize_site!(@site, :manage)
    end

    def back_to_form(message) = redirect_to(site_ha_migration_path(@site), alert: message)
  end
end
