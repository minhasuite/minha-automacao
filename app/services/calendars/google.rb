module Calendars
  # Google Agenda pela API oficial (OAuth 2.0, escopo só de leitura). Liga só
  # com GOOGLE_CLIENT_ID e GOOGLE_CLIENT_SECRET (credencial vazia = desligado).
  # O refresh token fica nas credenciais cifradas da integração; o access token
  # (1 h) é renovado aqui quando vence.
  module Google
    AUTH = "https://accounts.google.com/o/oauth2/v2/auth".freeze
    TOKEN = "https://oauth2.googleapis.com/token".freeze
    API = "https://www.googleapis.com/calendar/v3".freeze
    SCOPE = "https://www.googleapis.com/auth/calendar.readonly".freeze

    module_function

    def client_id = ENV["GOOGLE_CLIENT_ID"].presence
    def client_secret = ENV["GOOGLE_CLIENT_SECRET"].presence
    def configured? = client_id.present? && client_secret.present?

    # Também serve ao backup no Drive (outro escopo). `access_token` aceita
    # qualquer dono de `secrets`/`merge_secrets!`, não só a integração.
    def auth_url(redirect_uri, state, scope: SCOPE)
      query = { client_id: client_id, redirect_uri: redirect_uri, response_type: "code", scope: scope,
                access_type: "offline", prompt: "consent", state: state }
      "#{AUTH}?#{URI.encode_www_form(query)}"
    end

    # code → {"refresh_token", "access_token", "expires_at"}.
    def exchange(code, redirect_uri)
      raise Integrations::Error, "Sem o código do Google." if code.blank?

      tokens(grant_type: "authorization_code", code: code, redirect_uri: redirect_uri)
    end

    def access_token(integration)
      s = integration.secrets
      raise Integrations.auth(Integrations::Error.new("Falta entrar com o Google.")) if s["refresh_token"].blank?
      return s["access_token"] if s["access_token"].present? && s["expires_at"].to_i > Time.current.to_i + 60

      fresh = tokens(grant_type: "refresh_token", refresh_token: s["refresh_token"])
      integration.merge_secrets!(fresh.except("refresh_token").merge(fresh["refresh_token"] ? { "refresh_token" => fresh["refresh_token"] } : {}))
      fresh["access_token"]
    end

    # [{id:, name:, events:}] das agendas marcadas na conta. Agenda compartilhada
    # só como "livre/ocupado" (a de outra empresa, por exemplo) também entra:
    # os horários ocupados viram eventos "Ocupado", sem título (BUSY).
    BUSY = "Ocupado".freeze

    def calendars(integration, from, to)
      token = access_token(integration)
      list = get("#{API}/users/me/calendarList?minAccessRole=freeBusyReader", token)["items"].to_a.reject { |c| c["hidden"] || c["selected"] == false }.first(20)
      busy_only, readable = list.partition { |c| c["accessRole"] == "freeBusyReader" }
      busy = busy_only.any? ? busy(token, busy_only.pluck("id"), from, to) : {}
      list.map do |c|
        evs = busy_only.include?(c) ? busy.fetch(c["id"], []) : events(token, c["id"], from, to)
        { id: "google:#{c['id']}", name: c["summaryOverride"].presence || c["summary"].to_s, events: evs }
      end
    end

    # Livre/ocupado: {id => [eventos "Ocupado"]}; agenda com erro fica vazia.
    def busy(token, ids, from, to)
      res = SafeHttp.request("POST", "#{API}/freeBusy", headers: { "Authorization" => "Bearer #{token}", "Content-Type" => "application/json" },
                                                         body: { timeMin: from.utc.iso8601, timeMax: to.utc.iso8601, items: ids.map { |i| { id: i } } }.to_json)
      body = parse(res)
      raise Integrations::Error, body.dig("error", "message") || "Google respondeu #{res.status}" unless res.status == 200

      body["calendars"].to_h.transform_values do |c|
        c["busy"].to_a.first(Calendars::MAX_EVENTS).map do |b|
          { "summary" => BUSY, "start" => Time.zone.parse(b["start"]).iso8601, "end" => Time.zone.parse(b["end"]).iso8601, "all_day" => false, "busy" => true }
        end
      end
    end

    def events(token, calendar_id, from, to)
      q = URI.encode_www_form(timeMin: from.utc.iso8601, timeMax: to.utc.iso8601, singleEvents: true, orderBy: "startTime", maxResults: Calendars::MAX_EVENTS)
      items = get("#{API}/calendars/#{ERB::Util.url_encode(calendar_id)}/events?#{q}", token)["items"].to_a
      items.reject { |e| e["status"] == "cancelled" }.map do |e|
        all_day = e.dig("start", "date").present?
        s = all_day ? Time.zone.parse(e.dig("start", "date")) : Time.zone.parse(e.dig("start", "dateTime"))
        f = all_day ? Time.zone.parse(e.dig("end", "date")) : Time.zone.parse(e.dig("end", "dateTime"))
        { "summary" => e["summary"].presence || "(sem título)", "start" => s.iso8601, "end" => f.iso8601, "all_day" => all_day,
          "location" => e["location"].presence,
          # Tipo do Google fora o comum: "birthday" (os aniversários, que desde 2024 moram
          # na agenda principal), "outOfOffice", "focusTime"…
          "type" => (e["eventType"] if e["eventType"].present? && e["eventType"] != "default") }.compact
      end
    end

    def tokens(**form)
      res = SafeHttp.request("POST", TOKEN, headers: { "Content-Type" => "application/x-www-form-urlencoded" },
                                            body: URI.encode_www_form(form.merge(client_id: client_id, client_secret: client_secret)))
      body = parse(res)
      unless res.status == 200
        error = Integrations::Error.new(body["error_description"] || body["error"] || "erro #{res.status}")
        raise res.status.between?(400, 499) ? Integrations.auth(error) : error # 4xx = refresh_token recusado
      end

      { "access_token" => body["access_token"], "expires_at" => Time.current.to_i + body["expires_in"].to_i,
        "refresh_token" => body["refresh_token"] }.compact
    end

    def get(url, token)
      res = SafeHttp.get(url, headers: { "Authorization" => "Bearer #{token}" })
      body = parse(res)
      raise Integrations::Error, body.dig("error", "message") || "Google respondeu #{res.status}" unless res.status == 200

      body
    end

    def parse(res)
      JSON.parse(res.body.presence || "{}")
    rescue JSON::ParserError
      {}
    end
  end
end
