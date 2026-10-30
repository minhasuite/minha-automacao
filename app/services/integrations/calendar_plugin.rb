module Integrations
  # Google Agenda / ICS (F9). Dois modos:
  #   ics    — um ou mais links .ics (o "endereço secreto no formato iCal" do
  #            Google Agenda ou qualquer agenda pública); os links ficam cifrados;
  #   google — conta Google por OAuth (só leitura), disponível quando
  #            GOOGLE_CLIENT_ID e GOOGLE_CLIENT_SECRET estão no servidor.
  # Cada agenda vira um ponto `calendar` (valor = evento de agora ou o próximo)
  # no dispositivo virtual da integração. A leitura periódica é a varredura da
  # integração (`poll_s`, padrão 15 min); o "agora" anda a cada minuto (`tick`).
  class CalendarPlugin < Plugin
    describe key: "calendar", title: "Google Agenda / ICS", icon: "calendar",
             description: "Eventos de uma agenda (link iCal secreto do Google ou qualquer .ics, ou a conta Google) para gatilhos e painéis."

    POLL_S = 15 * 60

    def self.setup(site, form)
      if form[:mode] == "google"
        return outcome(:form, alert: "A conta Google ainda não está configurada neste servidor. Use o link iCal.") unless Calendars::Google.configured?

        integration = new_integration(site, name: "Google Agenda", status: "pending", poll_s: POLL_S)
        integration.settings = { "mode" => "google" }
        integration.save!
        return outcome(:connect, integration: integration)
      end

      urls = urls_from(form[:urls])
      return outcome(:form, alert: "Cole pelo menos um link que comece com https:// (ou http://).") if urls.empty?

      integration = new_integration(site, name: form[:name].presence || "Agenda", poll_s: POLL_S)
      integration.settings = { "mode" => "ics", "account" => "#{urls.size} link(s) iCal" }
      integration.credentials = { "urls" => urls }.to_json
      integration.save!
      read(integration, "Agenda conectada")
    end

    def self.login(integration, form)
      return outcome(:connect, integration: integration) if integration.settings["mode"] == "google"

      urls = urls_from(form[:urls])
      integration.update!(credentials: integration.secrets.merge("urls" => urls).to_json, settings: integration.settings.merge("account" => "#{urls.size} link(s) iCal")) if urls.any?
      read(integration, "Agenda atualizada")
    end

    def self.read(integration, notice)
      r = Integrations.sync!(integration)
      outcome(:index, notice: "#{notice}: #{r[:found]} agenda(s), #{r[:events]} evento(s) nos próximos 31 dias.")
    rescue Integrations::Error, SafeHttp::Error => e
      outcome(:index, alert: "Agenda salva, mas a leitura falhou: #{e.message}")
    end

    def self.urls_from(text) = text.to_s.split(/\s+/).select { |u| u.match?(%r{\Ahttps?://\S+\z}i) }.uniq.first(10)

    # Passo de login do modo Google: botão para o consentimento.
    def self.connect_locals(integration, params)
      return {} unless integration.settings["mode"] == "google"

      { auth_url: Calendars::Google.auth_url(params[:redirect_uri], Integrations.oauth_state(integration)) }
    end

    def self.oauth_callback(integration, params)
      tokens = Calendars::Google.exchange(params[:code], params[:redirect_uri])
      integration.update!(credentials: integration.secrets.merge(tokens).to_json, status: "ok")
      read(integration, "Conta Google conectada")
    rescue Integrations::Error => e
      integration.error!(e.message)
      outcome(:connect, integration: integration, alert: "O Google recusou: #{e.message}")
    end

    def self.custom_sync? = true

    # Lê cada agenda e grava os eventos no ponto dela. → {found:, events:, ...}
    def self.sync!(integration)
      from, to = Calendars.window
      zone = ActiveSupport::TimeZone[integration.site.timezone]
      calendars = integration.settings["mode"] == "google" ? Calendars::Google.calendars(integration, from, to) : ics(integration, zone, from, to)
      device = device_for(integration)
      points = calendars.map { |c| store(device, c) }
      device.points.where.not(id: points.map(&:id)).where(capability: "calendar").find_each { |p| p.report!(p.value, quality: "unavailable") }
      device.update_columns(last_seen_at: Time.current)
      integration.ok!
      { found: calendars.size, fresh: 0, removed: 0, keys: 0, events: calendars.sum { |c| c[:events].size } }
    rescue SafeHttp::Error, Integrations::Error => e
      integration.error!(e.message)
      raise Integrations::Error, e.message
    end

    def self.ics(integration, zone, from, to)
      Array(integration.secrets["urls"]).each_with_index.map do |url, i|
        res = SafeHttp.get(url, timeout: 20)
        raise Integrations::Error, "Link #{i + 1} respondeu #{res.status}." unless res.status == 200
        raise Integrations::Error, "Link #{i + 1} não é uma agenda iCal." unless res.body.include?("BEGIN:VCALENDAR")

        body = res.body.dup.force_encoding("UTF-8").scrub
        { id: "ics:#{Digest::SHA1.hexdigest(url)[0, 12]}", name: Calendars.calendar_name(body) || "Agenda #{i + 1}",
          events: Calendars.parse_ics(body, zone, from: from, to: to) }
      end
    end

    def self.device_for(integration)
      integration.site.devices.find_or_create_by!(driver: "virtual", external_id: "calendar:#{integration.id}") do |d|
        d.name = integration.name
        d.integration = integration
        d.manufacturer = integration.settings["mode"] == "google" ? "Google" : "iCal"
      end
    end

    def self.store(device, cal)
      point = device.points.find_by("address->>'calendar' = ?", cal[:id]) ||
              device.points.create!(site: device.site, name: cal[:name], key: Integrations.unique_key(device.site, device, cal[:name]),
                                    capability: "calendar", history: "none", address: { "calendar" => cal[:id] })
      Calendars.store!(point, cal[:events])
      point
    end

    def self.tick(now) = Calendars.tick(now)
  end
end
