require "rails_helper"

# Lote 9 (fechamento antes do corte): última fala às Echo como atributo,
# `trigger.attrs` no gatilho por atributo, opções de seleção uma por linha e
# "Limpar cômodos" por texto (JSON, ids ou nomes do mapa). Tudo sintético;
# a Amazon é simulada pelo WebMock.
RSpec.describe "Lote 9: fechamento da migração" do
  let(:tenant) { create(:tenant) }
  let(:site) { create(:site, name: "Local") }

  around { |ex| ActsAsTenant.with_tenant(tenant) { travel_to(Time.zone.parse("2026-10-31 22:00:00")) { ex.run } } }

  def listen!(point, attribute: "last_called_timestamp", conditions: [])
    a = Automation.create!(site: site, name: "Escuta #{SecureRandom.hex(2)}", kind: "automation", mode: "parallel")
    a.publish!({ "triggers" => [ { "type" => "state", "point" => point.id, "attribute" => attribute } ], "conditions" => conditions,
                 "actions" => [ { "type" => "trace_note", "message" => "{{ trigger.attrs.last_called_summary }}" } ] })
    a.update!(enabled: true)
    a
  end

  describe "última fala às Echo (Alexa::LastCalled)" do
    let(:integration) { Integration.create!(site: site, driver: "alexa", name: "Alexa", status: "ok", settings: { "host" => "alexa.amazon.com.br" }, credentials: { "cookies" => { "session-id" => "S1", "csrf" => "C1" } }.to_json) }
    let(:echo_dev) { create(:device, site: site, driver: "alexa", name: "Echo Sala", external_id: "G0SALA", integration: integration) }
    let(:outro_dev) { create(:device, site: site, driver: "alexa", name: "Echo Quarto", external_id: "G0QUARTO", integration: integration) }
    let!(:echo) { create(:point, site: site, device: echo_dev, name: "Falar", key: "echo_sala.falar", capability: "speaker", data_type: "json", writable: true) }
    let!(:outro) { create(:point, site: site, device: outro_dev, name: "Falar", key: "echo_quarto.falar", capability: "speaker", data_type: "json", writable: true, attrs: { "last_called" => true }) }
    let(:ts) { (Time.current - 20).to_i * 1000 }
    let(:records) do
      { "customerHistoryRecords" => [
        { "recordKey" => "CUST#A3S5#X#G0QUARTO", "timestamp" => ts - 60_000, "utteranceType" => "GENERAL",
          "voiceHistoryRecordItems" => [ { "recordItemType" => "CUSTOMER_TRANSCRIPT", "transcriptText" => "que horas são" } ] },
        { "recordKey" => "CUST#A3S5#X#G0SALA", "timestamp" => ts, "utteranceType" => "GENERAL",
          "voiceHistoryRecordItems" => [ { "recordItemType" => "ALEXA_RESPONSE", "transcriptText" => "ok" }, { "recordItemType" => "CUSTOMER_TRANSCRIPT", "transcriptText" => "boa noite" } ] },
        { "recordKey" => "CUST#A3S5#X#G0SALA", "timestamp" => ts + 1000, "utteranceType" => "WAKE_WORD_ONLY", "voiceHistoryRecordItems" => [] }
      ] }
    end

    def stub_amazon!
      page = stub_request(:get, %r{\Ahttps://www\.amazon\.com\.br/alexa-privacy/apd/activity}).to_return(body: '<html><meta name="csrf-token" content="TOK"></html>')
      post = stub_request(:post, %r{\Ahttps://www\.amazon\.com\.br/alexa-privacy/apd/rvh/customer-history-records-v2/})
             .with(headers: { "anti-csrftoken-a2z" => "TOK" }).to_return(body: records.to_json)
      [ page, post ]
    end

    it "lê o histórico, marca a Echo que ouviu e dispara o gatilho por atributo com trigger.attrs" do
      _, post = stub_amazon!
      a = listen!(echo, conditions: [ { "type" => "expr", "expr" => "timestamp * 1000 - trigger.attrs.last_called_timestamp < 120000" } ])
      expect { Integrations::AlexaPlugin.tick(Time.current) }.to change { a.runs.count }.by(1)
      expect(post).to have_been_requested.once
      expect(echo.reload.attrs).to eq("last_called" => true, "last_called_summary" => "boa noite", "last_called_timestamp" => ts)
      expect(outro.reload.attrs).to eq("last_called" => false)
      run = a.runs.last
      expect(run.trigger["attrs"]).to include("last_called_summary" => "boa noite")
      expect(run.status).to eq("done")
      expect(run.steps.to_json).to include("boa noite")
      # A mesma fala no próximo minuto não dispara de novo.
      expect { Integrations::AlexaPlugin.tick(Time.current + 60) }.not_to(change { a.runs.count })
    end

    it "sem automação escutando não chama a Amazon; erro de rede não para o relógio" do
      page, post = stub_amazon!
      Integrations::AlexaPlugin.tick(Time.current)
      expect(page).not_to have_been_requested
      expect(post).not_to have_been_requested

      listen!(echo)
      stub_request(:get, %r{www\.amazon\.com\.br}).to_raise(SocketError)
      expect { Integrations.tick(Time.current) }.not_to raise_error
    end

    it "página sem token anti-CSRF vira erro de sessão" do
      stub_request(:get, %r{www\.amazon\.com\.br}).to_return(body: "<html>login</html>")
      client = Alexa::Client.new(cookies: { "session-id" => "S1" })
      expect { client.voice_history(since: 10.minutes.ago) }.to raise_error(Alexa::Client::Error) { |e| expect(e).to be_a(Integrations::AuthError) }
    end
  end

  # Extensão: qualquer plugin que publica atributos entra no gatilho e no
  # `trigger.attrs` sem mexer no núcleo.
  it "plugin de integração falso (stub_const) publica atributo no tick e a automação lê trigger.attrs" do
    device = create(:device, site: site, driver: "virtual", name: "Sensor")
    p = create(:point, site: site, device: device, name: "Leitor", key: "leitor", capability: "text", data_type: "string", writable: false)
    fake = Class.new(Integrations::Plugin) do
      describe key: "falso_attrs", title: "Falso", icon: "cog", description: "teste"
      define_singleton_method(:tick) { |_now| Point.find_by(key: "leitor").report_attrs!("ultimo" => "abriu", "quem" => "fulano") }
    end
    stub_const("Integrations::FalsoAttrsPlugin", fake)
    stub_const("Integrations::PLUGINS", Integrations::PLUGINS + [ "FalsoAttrsPlugin" ])
    a = Automation.create!(site: site, name: "Leitura", kind: "automation", mode: "parallel")
    a.publish!({ "triggers" => [ { "type" => "state", "point" => p.id, "attribute" => "ultimo", "to" => "abriu" } ],
                 "conditions" => [ { "type" => "expr", "expr" => "trigger.attrs.quem = 'fulano'" } ],
                 "actions" => [ { "type" => "set", "var" => "quem", "value" => "{{ trigger.attrs.quem }}" } ] })
    a.update!(enabled: true)
    expect { Integrations.tick(Time.current) }.to change { a.runs.where(status: "done").count }.by(1)
    expect(a.runs.last.steps.to_json).to include("fulano")
  end

  it "opções de seleção uma por linha (importador do HA) ou por vírgula" do
    p = Point.new(site: site)
    p.options_text = "Escritório\nCozinha\nSuíte KH"
    expect(p.options).to eq([ "Escritório", "Cozinha", "Suíte KH" ])
    p.options_text = "A, B"
    expect(p.options).to eq(%w[A B])
  end

  describe "Limpar cômodos por texto" do
    let(:robo_dev) { create(:device, site: site, driver: "xiaomi_miot", name: "Robô") }
    let(:robo) do
      create(:point, site: site, device: robo_dev, name: "Robô", key: "robo", capability: "vacuum", data_type: "string", writable: true,
                     address: { "rooms" => [ { "id" => 5, "name" => "Sala de estar" }, { "id" => 45, "name" => "Cozinha" } ] })
    end

    it "aceita ids, nomes do mapa e JSON; recusa cômodo fora do mapa" do
      norm = ->(v) { Points::Command.new(robo, "clean_rooms", v).tap(&:new_value).value }
      expect(norm.call("5")).to eq("rooms" => [ 5 ])
      expect(norm.call("sala de estar, Cozinha")).to eq("rooms" => [ 5, 45 ])
      expect(norm.call('{"rooms": ["45"]}')).to eq("rooms" => [ 45 ])
      expect(norm.call({ "rooms" => [ 5 ] })).to eq("rooms" => [ 5 ])
      expect { norm.call("Garagem") }.to raise_error(Points::Command::Error, /desconhecido/)
      expect { norm.call("{quebrado") }.to raise_error(Points::Command::Error, /ao menos um/)
      expect { norm.call("") }.to raise_error(Points::Command::Error, /ao menos um/)
    end
  end
end
