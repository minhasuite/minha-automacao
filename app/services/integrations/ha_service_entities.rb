module Integrations
  # Entidades do HA que não são de um aparelho, e sim de um serviço que aqui
  # também existe como integração (clima, speedtest, o próprio servidor) →
  # o ponto equivalente daqui. Parte do importador (`HomeAssistantImport`,
  # passo "Serviços"), pelo de-para de sempre (`ExternalRef`).
  #
  # Serviço novo = uma entrada em `SERVICES`: plataforma do HA →
  # `driver` daqui, se a integração nasce sozinha (`create`: só as que não
  # pedem nada à pessoa) e as regras {id da entidade → campo do ponto daqui}.
  # A primeira regra que casa com o `unique_id` (ou o `entity_id`) vale; `:weather` = o ponto de
  # clima do aparelho da integração.
  module HaServiceEntities
    SERVICES = {
      "met" => { driver: "weather", create: true, rules: { /\Aweather\./ => :weather } },
      "open_meteo" => { driver: "weather", create: true, rules: { /\Aweather\./ => :weather } },
      "speedtestdotnet" => { driver: "speedtest", create: true,
                             rules: { /(download|baixar)\z/ => "download", /(upload|carregar)\z/ => "upload", /ping\z/ => "ping" } },
      "hassio" => { driver: "system", create: true,
                    rules: { /cpu_percent\z/ => "cpu", /memory_percent\z/ => "memory", /disk_used\z/ => "disk_used",
                             /disk_free\z/ => "disk_free", /\Aupdate\./ => "update_available" } },
      "uptime" => { driver: "system", create: true, rules: { /\Asensor\./ => "host_up_since" } },
      "backup" => { driver: "system", create: true,
                    rules: { /last_successful/ => "backup_at", /next_scheduled/ => "backup_next", /manager_state/ => "backup_state" } },
      # Google Agenda: o unique_id do HA é "<conta>-<id da agenda>"; a agenda daqui guarda o id (a conexão é da pessoa).
      "google" => { driver: "calendar", create: false, rules: { /\Acalendar\./ => :calendar } }
    }.freeze

    module_function

    # → [[entidade do HA, ponto daqui]] das entidades de serviço que acharam par.
    def call(site, registry)
      registry.filter_map do |e|
        next if e["disabled_by"].present?

        service = SERVICES[e["platform"].to_s] or next
        ids = [ e["unique_id"].to_s, e["entity_id"].to_s ]
        field = service[:rules].find { |re, _| ids.any? { |id| id.match?(re) } }&.last or next
        point = (field == :calendar ? calendar_point(site, e["unique_id"].to_s) : point_for(site, service, field)) and [ e, point ]
      end
    end

    def point_for(site, service, field)
      integration = integration_for(site, service) or return nil
      device = site.devices.where(integration_id: integration.id).or(site.devices.where("external_id LIKE ?", "%:#{integration.id}"))
      points = Point.where(device_id: device.select(:id))
      field == :weather ? points.find_by(capability: "weather") : points.find_by("address->>'field' = ?", field)
    end

    # Agenda daqui cujo id fecha o unique_id do HA (as variantes "-birthdays"/"-work-location" não casam).
    def calendar_point(site, uid)
      return nil if uid.blank?

      Point.joins(:device).where(devices: { site_id: site.id }, capability: "calendar")
           .find { |p| (id = p.address["calendar"].to_s).present? && uid.end_with?("-#{id}") }
    end

    # A integração do serviço; as que nascem sem pedir nada são criadas e lidas uma vez.
    def integration_for(site, service)
      @cache ||= {}
      @cache[[ site.id, service[:driver] ]] ||= (site.integrations.find_by(driver: service[:driver]) || (create(site, service[:driver]) if service[:create]))&.tap { |i| adopt(i) if service[:create] }
    end

    # O que a integração achou (o aparelho do speedtest) entra direto: no HA ele já estava em uso.
    def adopt(integration)
      Integrations.adopt!(integration, integration.found.to_h { |e| [ e["id"], nil ] }) if integration.found.present?
    end

    # Pelo `setup` do próprio plugin (o mesmo da tela), sem campos: só serve a quem não pede nada.
    def create(site, driver)
      plugin = Integrations.plugin(driver) or return nil
      plugin.setup(site, ActiveSupport::HashWithIndifferentAccess.new)
      site.integrations.find_by(driver: driver)
    rescue Integrations::Error, ActiveRecord::RecordInvalid => e
      Rails.logger.info("[ha_import] #{driver}: #{e.message}")
      site.integrations.find_by(driver: driver)
    end

    def reset! = @cache = nil
  end
end
