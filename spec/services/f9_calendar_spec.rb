require "rails_helper"

RSpec.describe "F9: Google Agenda / ICS" do
  include ActiveSupport::Testing::TimeHelpers

  let(:tenant) { create(:tenant) }
  let(:site) { within(tenant) { create(:site, name: "Casa") } }
  let(:zone) { ActiveSupport::TimeZone["America/Sao_Paulo"] }
  let(:now) { zone.parse("2026-11-02 09:00") } # segunda
  let(:url) { "https://calendar.google.com/calendar/ical/x/private-abc/basic.ics" }
  let(:ics) do
    <<~ICS.gsub("\n", "\r\n")
      BEGIN:VCALENDAR
      X-WR-CALNAME:Família
      BEGIN:VEVENT
      UID:feriado
      DTSTART;VALUE=DATE:20261102
      DTEND;VALUE=DATE:20261103
      SUMMARY:Finados
      END:VEVENT
      BEGIN:VEVENT
      UID:reuniao
      DTSTART;TZID=America/Sao_Paulo:20261102T083000
      DTEND;TZID=America/Sao_Paulo:20261102T093000
      SUMMARY:Reunião\\, com o time
      LOCATION:Escritório
      END:VEVENT
      BEGIN:VEVENT
      UID:academia
      DTSTART:20261026T220000Z
      DURATION:PT1H
      RRULE:FREQ=WEEKLY;BYDAY=MO,WE;COUNT=6
      EXDATE:20261104T220000Z
      SUMMARY:Academia
      END:VEVENT
      BEGIN:VEVENT
      UID:academia
      RECURRENCE-ID:20261109T220000Z
      DTSTART:20261109T230000Z
      DTEND:20261110T000000Z
      SUMMARY:Academia (mais tarde)
      END:VEVENT
      BEGIN:VEVENT
      UID:cancelado
      DTSTART:20261103T120000Z
      DTEND:20261103T130000Z
      STATUS:CANCELLED
      SUMMARY:Cancelado
      END:VEVENT
      BEGIN:VEVENT
      UID:diario
      DTSTART;TZID=America/Sao_Paulo:20261101T070000
      DTEND;TZID=America/Sao_Paulo:20261101T071500
      RRULE:FREQ=DAILY;INTERVAL=2;UNTIL=20261106T000000Z
      SUMMARY:Remédio
      DESCRIPTION:linha longa que continua
       na linha seguinte
      END:VEVENT
      END:VCALENDAR
    ICS
  end

  around { |ex| ActsAsTenant.with_tenant(tenant) { travel_to(now) { ex.run } } }

  describe Calendars do
    it "lê dia inteiro, fuso, escape, recorrência semanal/diária, exceção, remarcação e cancelado" do
      list = described_class.parse_ics(ics, zone, from: now - 1.day, to: now + 31.days)
      names = list.map { |e| [ e["summary"], Time.zone.parse(e["start"]).in_time_zone(zone).strftime("%d %H:%M") ] }
      expect(names).to include([ "Finados", "02 00:00" ], [ "Reunião, com o time", "02 08:30" ],
                               [ "Remédio", "03 07:00" ], [ "Remédio", "05 07:00" ], [ "Academia", "02 19:00" ], [ "Academia (mais tarde)", "09 20:00" ])
      expect(names.map(&:first)).not_to include("Cancelado")
      academia = names.select { |n, _| n == "Academia" }.map(&:last)
      expect(academia).to eq([ "02 19:00", "11 19:00" ]) # 26/10 e 28/10 fora da janela, 04 na EXDATE, 09 remarcado; COUNT=6
      expect(names.count { |n, _| n == "Remédio" }).to eq(2) # 01/11 já acabou antes da janela; 07/11 passa do UNTIL
      finados = list.find { |e| e["summary"] == "Finados" }
      expect(finados).to include("all_day" => true)
      expect(Time.zone.parse(finados["end"]) - Time.zone.parse(finados["start"])).to eq(1.day)
      expect(list.find { |e| e["summary"].start_with?("Reunião") }["location"]).to eq("Escritório")
      expect(described_class.calendar_name(ics)).to eq("Família")
      expect(described_class.duration("P1W2DT3H4M5S")).to eq((9 * 86_400) + (3 * 3600) + 245)
      expect(described_class.parse_ics("lixo", zone, from: now, to: now + 1.day)).to eq([])
    end
  end

  describe Integrations::CalendarPlugin do
    def setup(form) = described_class.setup(site, form.with_indifferent_access)

    it "modo ICS: link cifrado, um ponto por agenda com o evento de agora, leitura periódica e erro do link" do
      stub_request(:get, url).to_return(body: ics)
      o = setup(mode: "ics", name: "Família", urls: "#{url}\nnao-e-link")
      expect(o.to).to eq(:index)
      expect(o.notice).to include("1 agenda(s)")
      integration = Integration.sole
      expect(integration).to have_attributes(driver: "calendar", status: "ok", poll_s: 900)
      expect(integration.credentials).to include(url) # cifrado no banco
      expect(Integration.connection.select_value("SELECT credentials FROM integrations")).not_to include(url)
      point = site.points.find_by!(capability: "calendar")
      expect(point).to have_attributes(name: "Família", writable: false, quality: "good")
      expect(point.device).to have_attributes(driver: "virtual", integration_id: integration.id)
      expect(point.value).to include("summary" => "Finados", "now" => true)
      expect(ApplicationController.helpers.point_value_text(point)).to eq("Agora: Finados")

      expect { described_class.sync!(integration) }.not_to(change { site.points.count })
      stub_request(:get, url).to_return(status: 404)
      expect { Integrations.sync!(integration) }.to raise_error(Integrations::Error, /respondeu 404/)
      expect(integration.reload.status).to eq("error")

      expect(setup(mode: "ics", urls: "").alert).to include("Cole pelo menos um link")
      stub_request(:get, url).to_return(body: "<html>")
      expect(described_class.login(integration, { urls: url }.with_indifferent_access).alert).to include("não é uma agenda")
    end

    it "valor anda com o relógio (tick) e o texto do próximo evento" do
      stub_request(:get, url).to_return(body: ics)
      setup(mode: "ics", urls: url)
      point = site.points.find_by!(capability: "calendar")
      point.update!(address: point.address.merge("events" => point.address["events"].reject { |e| e["all_day"] }))
      Integrations.tick(zone.parse("2026-11-02 08:40"))
      expect(point.reload.value).to include("summary" => "Reunião, com o time", "now" => true)
      Integrations.tick(zone.parse("2026-11-02 10:00"))
      expect(ApplicationController.helpers.point_value_text(point.reload)).to eq("Academia · hoje 19:00")
      expect(ApplicationController.helpers.calendar_text(nil)).to eq("Nada nos próximos dias")
      expect(ApplicationController.helpers.calendar_text({ "summary" => "X", "start" => (now + 1.day).iso8601 })).to eq("X · amanhã 09:00")
      expect(ApplicationController.helpers.calendar_text({ "summary" => "Y", "start" => (now + 3.days).iso8601, "all_day" => true })).to start_with("Y · ")
    end

    it "gatilho começou/terminou com filtro e antecedência; condição há evento agora" do
      stub_request(:get, url).to_return(body: ics)
      setup(mode: "ics", urls: url)
      point = site.points.find_by!(capability: "calendar")
      trig = Automations::TriggerTypes["calendar"]
      t = { "type" => "calendar", "point" => point.id, "event" => "start", "contains" => "reunião", "offset" => "-15m" }
      expect(trig.due?(t, site, zone.parse("2026-11-02 08:15"))).to be(true)
      expect(trig.due?(t, site, zone.parse("2026-11-02 08:30"))).to be(false)
      expect(trig.due?(t.merge("event" => "end", "offset" => nil), site, zone.parse("2026-11-02 09:30"))).to be(true)
      expect(trig.due?(t.merge("contains" => "academia"), site, zone.parse("2026-11-02 08:15"))).to be(false)
      expect(trig.due?(t.merge("point" => SecureRandom.uuid), site, zone.parse("2026-11-02 08:15"))).to be(false)
      expect(trig.title(t)).to eq("Evento começou (\"reunião\")")

      a = Automation.create!(site: site, name: "Reunião")
      definition = { "triggers" => [ t ], "conditions" => [ { "type" => "calendar", "point" => point.id, "contains" => "finados" } ],
                     "actions" => [ { "type" => "set", "var" => "x", "value" => "ok" } ] }
      expect(Automations::Dsl.errors(definition, site)).to be_empty
      a.publish!(definition)
      a.update!(enabled: true)
      expect { Automations::Triggers.tick(zone.parse("2026-11-02 08:15")) }.to change { a.runs.count }.by(1)
      expect(a.runs.last).to have_attributes(status: "done")
      checks = Automations::ConditionTypes["calendar"]
      expect(Automations::Dsl.errors(definition.merge("conditions" => [ { "type" => "calendar" } ]), site).join).to include("falta agenda")
      expect(checks.label).to eq("Há evento agora")
    end

    it "modo Google: só com cliente configurado, OAuth, agendas, renovação do token e erro" do
      expect(setup(mode: "google").alert).to include("não está configurada")
      stub_const("ENV", ENV.to_h.merge("GOOGLE_CLIENT_ID" => "cid", "GOOGLE_CLIENT_SECRET" => "csec"))
      o = setup(mode: "google")
      integration = o.integration
      expect([ o.to, integration.status ]).to eq([ :connect, "pending" ])
      url = described_class.connect_locals(integration, { redirect_uri: "https://casa/integracoes/oauth/retorno" })[:auth_url]
      expect(url).to include("accounts.google.com", "client_id=cid", "calendar.readonly", "access_type=offline", "state=")
      expect(Integrations.from_oauth_state(Rack::Utils.parse_query(URI(url).query)["state"])).to eq(integration.id)
      expect { described_class.sync!(integration) }.to raise_error(Integrations::Error, /Falta entrar/)

      token = stub_request(:post, "https://oauth2.googleapis.com/token")
              .with(body: hash_including("grant_type" => "authorization_code", "code" => "C1", "client_secret" => "csec"))
              .to_return(body: { access_token: "A1", refresh_token: "R1", expires_in: 3600 }.to_json)
      stub_request(:get, %r{calendar/v3/users/me/calendarList}).with(headers: { "Authorization" => "Bearer A1" })
                                                               .to_return(body: { items: [ { id: "eu@gmail.com", summary: "Eu" }, { id: "x", summary: "Oculta", hidden: true } ] }.to_json)
      stub_request(:get, %r{calendar/v3/calendars/eu(@|%40)gmail.com/events}).to_return(body: { items: [
        { summary: "Dentista", start: { dateTime: "2026-11-02T10:00:00-03:00" }, end: { dateTime: "2026-11-02T11:00:00-03:00" } },
        { summary: "Viagem", start: { date: "2026-11-05" }, end: { date: "2026-11-07" } },
        { status: "cancelled", start: { date: "2026-11-05" }, end: { date: "2026-11-06" } }
      ] }.to_json)
      o = described_class.oauth_callback(integration, { code: "C1", redirect_uri: "https://casa/r" })
      expect(token).to have_been_requested
      expect(o.notice).to include("1 agenda(s), 2 evento(s)")
      point = site.points.find_by!(capability: "calendar")
      expect(point.name).to eq("Eu")
      expect(point.value).to include("summary" => "Dentista", "now" => false)
      expect(integration.reload.secrets).to include("refresh_token" => "R1", "access_token" => "A1")

      travel 2.hours
      stub_request(:post, "https://oauth2.googleapis.com/token").with(body: hash_including("grant_type" => "refresh_token", "refresh_token" => "R1"))
                                                                .to_return(body: { access_token: "A2", expires_in: 3600 }.to_json)
      stub_request(:get, %r{calendarList}).to_return(body: { items: [] }.to_json)
      expect(described_class.sync!(integration)).to include(found: 0)
      expect(point.reload.quality).to eq("unavailable")
      expect(integration.reload.secrets).to include("refresh_token" => "R1", "access_token" => "A2")

      stub_request(:post, "https://oauth2.googleapis.com/token").to_return(status: 400, body: { error: "invalid_grant" }.to_json)
      expect(described_class.oauth_callback(integration, { code: "X", redirect_uri: "r" }).alert).to include("invalid_grant")
      expect(described_class.login(integration, {}).to).to eq(:connect)
    end

    it "modo Google: agenda só livre/ocupado vira horários \"Ocupado\" e aniversário guarda o tipo" do
      stub_const("ENV", ENV.to_h.merge("GOOGLE_CLIENT_ID" => "cid", "GOOGLE_CLIENT_SECRET" => "csec"))
      integration = setup(mode: "google").integration
      integration.merge_secrets!("refresh_token" => "R1", "access_token" => "A1", "expires_at" => 1.hour.from_now.to_i)
      list = stub_request(:get, %r{calendarList\?minAccessRole=freeBusyReader}).to_return(body: { items: [
        { id: "eu@gmail.com", summary: "Eu", accessRole: "owner" },
        { id: "herlon@empresa.com", summary: "herlon@empresa.com", accessRole: "freeBusyReader" }
      ] }.to_json)
      stub_request(:get, %r{calendars/eu(@|%40)gmail.com/events}).to_return(body: { items: [
        { summary: "Aniversário de Ana", eventType: "birthday", start: { date: "2026-11-03" }, end: { date: "2026-11-04" } },
        { summary: "Dentista", eventType: "default", start: { dateTime: "2026-11-02T10:00:00-03:00" }, end: { dateTime: "2026-11-02T11:00:00-03:00" } }
      ] }.to_json)
      fb = stub_request(:post, "https://www.googleapis.com/calendar/v3/freeBusy")
           .with(body: hash_including("items" => [ { "id" => "herlon@empresa.com" } ]))
           .to_return(body: { calendars: { "herlon@empresa.com" => { busy: [ { start: "2026-11-02T12:00:00Z", end: "2026-11-02T13:00:00Z" } ] } } }.to_json)
      expect(described_class.sync!(integration)).to include(found: 2)
      expect([ list, fb ]).to all(have_been_requested)
      eu = site.points.find_by!(name: "Eu")
      expect(eu.address["events"]).to include(a_hash_including("summary" => "Aniversário de Ana", "type" => "birthday", "all_day" => true))
      expect(eu.address["events"].find { |e| e["summary"] == "Dentista" }).not_to have_key("type")
      empresa = site.points.find_by!(name: "herlon@empresa.com")
      expect(empresa.address["events"]).to eq([ { "summary" => "Ocupado", "start" => Time.zone.parse("2026-11-02T12:00:00Z").iso8601,
                                                   "end" => Time.zone.parse("2026-11-02T13:00:00Z").iso8601, "all_day" => false, "busy" => true } ])
    end
  end
end
