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
      return back_to_form("Informe o endereço do Home Assistant e um token de acesso longo.") unless plugin.configure(integration, params)

      integration.save!
      plugin.get(integration, "/api/") # testa na hora: endereço bloqueado ou token recusado voltam já
      integration.ok!
      Integrations::HaMigration.save_state!(integration, { "status" => "fetching", "started_at" => Time.current.iso8601 })
      HaMigrationJob.perform_later(integration.id, "fetch")
      redirect_to site_ha_migration_path(@site)
    rescue Integrations::Error => e
      integration&.error!(e) if integration&.persisted?
      back_to_form("O Home Assistant não respondeu: #{e.message}")
    end

    def import
      integration = Integrations::HaMigration.integration(@site) or return redirect_to(site_ha_migration_path(@site))
      choice = { "helpers" => params[:helpers] == "1" }.merge(%w[automations scripts scenes].to_h { |k| [ k, Array(params[k]).compact_blank.first(500) ] })
      state = Integrations::HaMigration.state(integration)
      Integrations::HaMigration.save_state!(integration, state.merge("status" => "importing", "choice" => choice, "progress" => nil, "error" => nil))
      HaMigrationJob.perform_later(integration.id, "import", choice)
      redirect_to site_ha_migration_path(@site)
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
