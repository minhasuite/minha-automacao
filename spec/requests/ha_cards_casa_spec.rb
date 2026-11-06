require "rails_helper"

# Cards dos painéis do HA que ainda quebravam: coluna vazia ("&nbsp;"),
# auto-entities (HACS) como Lista automática, "Falar na Alexa" (texto, Echo e
# voz gravada) e a Google Agenda do HA casando com a daqui. Nada fala com HA,
# Amazon ou ffmpeg de verdade.
RSpec.describe "HA: cards da casa" do
  let(:user) { create(:user) }
  let(:tenant) { user.tenant }
  let!(:site) { within(tenant) { create(:site, name: "Casa Teste") } }
  let(:src) { "home_assistant" }

  def sign_in(u = user) = post("/entrar", params: { email: u.email, password: "12345678" })

  def translate(cards, refs)
    config = { "views" => [ { "path" => "casa", "title" => "Casa", "sections" => cards } ] }
    Dashboards::HaImport.new(config, refs: refs, url_path: "casa", image: ->(_) { }, theme: nil).call
  end

  it "coluna só com &nbsp; vira seção espaçadora (sem texto), escondida no celular" do
    defn = within(tenant) do
      sections = [ { "type" => "grid", "cards" => [ { "type" => "markdown", "text_only" => true, "content" => "&nbsp;",
                                                      "visibility" => [ { "condition" => "screen", "media_query" => "(min-width: 601px)" } ] } ] },
                   { "type" => "grid", "cards" => [ { "type" => "heading", "heading" => "Mídia" } ] } ]
      defn = translate(sections, { "entity" => {} }).definition
      spacer, media = defn.dig("views", 0, "sections")
      expect(spacer).to include("spacer" => true, "widgets" => [])
      expect(media["widgets"].first).to include("type" => "heading", "title" => "Mídia")
      expect(Dashboards::Schema.errors(defn)).to be_empty
      defn
    end
    dash = within(tenant) { site.dashboards.create!(name: "Casa", kind: "custom", auto: false, definition: defn).tap { |d| d.publish!(defn) } }
    sign_in(user)
    get "/paineis/#{dash.id}"
    expect(response.body).not_to include("&amp;nbsp;")
    expect(response.body).to include('dw-hide-mobile" style="--m: 12')
  end

  it "auto-entities: entidades fixas + etiqueta viram consultas somadas, com nomes, tiles, exclusões e automações que rodaram" do
    within(tenant) do
      dev = create(:device, site: site, name: "Teste Luzes", driver: "virtual")
      mk = ->(ent, name, **o) { create(:point, site: site, device: dev, name: name, key: ent.tr(".", "_"), capability: "onoff", **o).tap { |p| ExternalRef.link!(site, src, ent, kind: "entity", target: p) } }
      cozinha = mk.("switch.cozinha", "Interruptor cozinha", value: true)
      sala = mk.("switch.sala", "Interruptor sala", value: false)
      varanda = mk.("light.varanda", "Varanda", value: true)
      trava = mk.("switch.trava_para_criancas", "Trava", value: true)
      Tagging.create!(tag: Tag.create!(name: "iluminação"), taggable: varanda)
      card = { "type" => "custom:auto-entities", "card" => { "type" => "grid", "columns" => 4 }, "sort" => { "method" => "name" },
               "filter" => { "include" => [ { "entity_id" => "switch.cozinha", "state" => "on", "options" => { "name" => "Cozinha" } },
                                            { "entity_id" => "switch.sala", "state" => "on", "options" => { "name" => "Sala" } },
                                            { "label" => "iluminacao", "state" => "on" } ],
                             "exclude" => [ { "entity_id" => "*trava_para_criancas*" }, { "integration" => "alexa_media" } ] },
               "else" => { "type" => "markdown", "content" => "Todas as luzes estão apagadas." } }
      refs = Integrations::HaDashboards.refs_for(site, {}).merge("label" => { "iluminacao" => "Iluminação" })
      result = translate([ { "type" => "grid", "cards" => [ card ] } ], refs)
      w = result.definition.dig("views", 0, "sections", 0, "widgets", 0)
      expect(w).to include("type" => "query_list", "display" => "tiles", "empty_text" => "Todas as luzes estão apagadas.",
                           "labels" => { cozinha.id => "Cozinha", sala.id => "Sala" })
      expect(w["query"]).to include("id" => cozinha.id, "state" => "on", "quality" => "good", "sort" => "name", "not_id" => trava.id, "not_integration" => "alexa")
      expect(w["or"].last).to include("tag" => "iluminação", "state" => "on")
      expect(result.notes.join).not_to include("auto-entities")
      expect(Dashboards::Schema.errors(result.definition)).to be_empty

      dash = site.dashboards.create!(name: "Casa", kind: "custom", auto: false, definition: result.definition)
      data = Dashboards::Resolver.new(dash, role: "owner").call
      list = data.dig("views", 0, "sections", 0, "widgets", 0, "data")
      expect(list["point_ids"]).to eq([ cozinha.id, varanda.id ]) # sala desligada; trava fora; ordem do nome
      expect(sala.id).not_to be_nil

      # Editar no editor não perde o que o formulário não mostra.
      kept = Dashboards::Widgets::QueryListWidget.keep(w, { "type" => "query_list", "query" => { "state" => "off" } })
      expect(kept).to include("or" => w["or"], "labels" => w["labels"])
      expect(kept["query"]).to include("id" => cozinha.id, "state" => "off")

      # Automações: as ligadas (sem as luzes) e as que rodaram nas últimas 24 h, da mais recente.
      a1 = Automation.create!(site: site, name: "Rodou agora", enabled: false)
      a2 = Automation.create!(site: site, name: "Rodou ontem cedo", enabled: false)
      a1.update_columns(last_run_at: 5.minutes.ago)
      a2.update_columns(last_run_at: 30.hours.ago)
      ran = translate([ { "type" => "grid", "cards" => [ { "type" => "custom:auto-entities", "card" => { "type" => "entities" },
                                                           "sort" => { "method" => "last_triggered", "reverse" => true },
                                                           "filter" => { "include" => [ { "domain" => "automation", "last_triggered" => "< 1440" } ] } } ] } ], refs)
      q = ran.definition.dig("views", 0, "sections", 0, "widgets", 0, "query")
      expect(q).to eq("automation" => "true", "ran_min" => "1440", "sort" => "-ran_at")
      expect(Points::Query.new(site).call(q).map(&:name)).to eq([ "Rodou agora" ])
      expect(Points::Query.new(site).call({ "capability" => "onoff", "automation" => "false" }).map(&:name)).not_to include("Rodou agora")

      # Bateria pelo atributo device_class (não "todo sensor abaixo de 30"); campo desconhecido descarta a regra;
      # vertical-stack = a lista num card só (linhas, sem "display" de tiles).
      att = translate([ { "type" => "grid", "cards" => [ { "type" => "custom:auto-entities", "card" => { "type" => "vertical-stack" },
                                                           "filter" => { "include" => [ { "domain" => "sensor", "attributes" => { "device_class" => "battery" }, "state" => "< 30" },
                                                                                        { "domain" => "sensor", "nome_estranho" => "x" } ] } } ] } ], refs)
      aw = att.definition.dig("views", 0, "sections", 0, "widgets", 0)
      expect(aw).to include("query" => { "capability" => "measure", "device_class" => "battery", "below" => "30" })
      expect(aw).not_to have_key("display")
      expect(aw).not_to have_key("or")
      expect(att.notes.join).to include("nome_estranho")

      # Atributo do sensor calculado (`attributes: {tuya_fora: "> 0"}`).
      falhas = create(:point, site: site, device: dev, name: "Falhas", key: "luzes_falhas", capability: "measure", value: 1, attrs: { "tuya_fora" => 2 })
      ExternalRef.link!(site, src, "sensor.falhas", kind: "entity", target: falhas)
      at2 = translate([ { "type" => "grid", "cards" => [ { "type" => "custom:auto-entities", "card" => { "type" => "vertical-stack" },
                                                           "filter" => { "include" => [ { "entity_id" => "sensor.falhas", "attributes" => { "tuya_fora" => "> 0" } } ] } } ] } ],
                      Integrations::HaDashboards.refs_for(site, {}))
      q2 = at2.definition.dig("views", 0, "sections", 0, "widgets", 0, "query")
      expect(q2).to eq("id" => falhas.id, "attr" => "tuya_fora>0")
      expect(Points::Query.new(site).call(q2)).to eq([ falhas ])
      falhas.update!(attrs: { "tuya_fora" => 0 })
      expect(Points::Query.new(site).call(q2)).to be_empty

      # Firmware com versão nova = o `update.*` ligado do HA.
      fw = create(:point, site: site, device: dev, name: "Firmware", key: "luzes_fw", capability: "update",
                          value: { "installed" => "1.0", "latest" => "1.1", "state" => "available" })
      upd = translate([ { "type" => "grid", "cards" => [ { "type" => "custom:auto-entities", "card" => { "type" => "vertical-stack" },
                                                           "filter" => { "include" => [ { "domain" => "update", "state" => "on" } ] } } ] } ], refs)
      q = upd.definition.dig("views", 0, "sections", 0, "widgets", 0, "query")
      expect(Points::Query.new(site).call(q)).to eq([ fw ])
    end
  end

  context "Falar na Alexa" do
    let!(:echos) do
      within(tenant) do
        integration = Integration.create!(site: site, driver: "alexa", name: "Teste Alexa", status: "ok", settings: { "host" => "alexa.amazon.com.br" },
                                          credentials: { "cookies" => { "session-id" => "S1" } }.to_json)
        %w[Cozinha Escritório].map do |n|
          dev = create(:device, site: site, integration: integration, driver: "alexa", name: "Teste Echo #{n}", external_id: "G0#{n[0, 3].upcase}")
          create(:point, site: site, device: dev, name: "Alto-falante", key: "echo_#{n[0, 3].downcase}", capability: "speaker", writable: true)
        end
      end
    end

    it "o card do HA com seletor vira o widget, que lista as Echos e manda o texto como anúncio" do
      card = { "type" => "custom:casa-campo-texto", "entity" => "input_text.alexa_mensagem", "name" => "Falar na Alexa",
               "icon" => "mdi:message-text-outline", "placeholder" => "Escreva ou grave um áudio", "acao" => "script.alexa_falar",
               "audio" => "script.alexa_falar", "seletor" => "input_select.alexa_destino" }
      defn = within(tenant) { translate([ { "type" => "grid", "cards" => [ card ] } ], { "entity" => {} }).definition }
      expect(defn.dig("views", 0, "sections", 0, "widgets", 0)).to include("type" => "announce", "label" => "Falar na Alexa",
                                                                           "placeholder" => "Escreva ou grave um áudio")
      dash = within(tenant) { site.dashboards.create!(name: "Casa", kind: "custom", auto: false, definition: defn).tap { |d| d.publish!(defn) } }

      sign_in(user)
      get "/paineis/#{dash.id}"
      expect(response.body).to include("data-controller=\"announce\"", "Teste Echo Cozinha", "Teste Echo Escritório", "Todas", "Escreva ou grave um áudio")

      post "/locais/#{site.id}/falar-na-alexa", params: { targets: "all", text: "Chegou <b>visita</b> & entrega" }, as: :json
      expect(response).to have_http_status(:ok)
      cmds = within(tenant) { Command.order(:created_at).last(2) }
      expect(cmds.map(&:command).uniq).to eq([ "announce" ])
      expect(cmds.map(&:value).uniq).to eq([ "Chegou bvisita/b e entrega" ])
      expect(cmds.map(&:point_id)).to match_array(echos.map(&:id))

      post "/locais/#{site.id}/falar-na-alexa", params: { targets: echos.first.id, text: " " }
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]).to eq("Escreva o que a Echo deve falar.")
    end

    it "voz gravada: vira MP3, a Echo toca pelo link curto e público; sem https de fora, recusa" do
      audio = -> { Rack::Test::UploadedFile.new(StringIO.new("webm-teste"), "audio/webm", original_filename: "fala.webm") }
      post "/api/v1/sites/#{site.id}/talk", params: { targets: echos.last.id, audio: audio.call }, headers: auth_headers(user)
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.to_json).to include("MEDIA_PUBLIC_URL")

      stub_const("ENV", ENV.to_h.merge("MEDIA_PUBLIC_URL" => "https://casa.teste"))
      allow(Alexa::Talk).to receive(:ffmpeg?).and_return(true)
      allow(Open3).to receive(:capture3).and_return([ "ID3mp3-teste".b, "", instance_double(Process::Status, success?: true) ])
      post "/api/v1/sites/#{site.id}/talk", params: { targets: echos.last.id, audio: audio.call }, headers: auth_headers(user)
      expect(response).to have_http_status(:accepted)
      cmd = within(tenant) { Command.order(:created_at).last }
      expect(cmd).to have_attributes(command: "speak", point_id: echos.last.id)
      url = cmd.value[%r{https://casa\.teste/fala/([a-z0-9]+)\.mp3}]
      expect(url).to be_present
      expect(cmd.value.length).to be <= Alexa::Client::MAX_TEXT

      get URI(url).path
      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("audio/mpeg")
      expect(response.body).to eq("ID3mp3-teste")
      get "/fala/naoexiste0000000000000000000.mp3"
      expect(response).to have_http_status(:not_found)
    end
  end

  it "data e hora em ISO aparece legível (último backup, servidor ligado desde)" do
    within(tenant) do
      dev = create(:device, site: site, name: "Teste Servidor", driver: "virtual")
      backup = create(:point, site: site, device: dev, name: "Último backup", key: "srv_backup", capability: "datetime", value: "2026-11-03T16:11:21-03:00")
      dia = create(:point, site: site, device: dev, name: "Dia", key: "srv_dia", capability: "datetime", value: "2026-11-03")
      livre = create(:point, site: site, device: dev, name: "Livre", key: "srv_livre", capability: "datetime", value: "amanhã")
      I18n.with_locale(:"pt-BR") do
        h = ApplicationController.helpers
        expect([ backup, dia, livre ].map { |p| h.point_value_text(p) }).to eq([ "03 de novembro, 16:11", "03 de novembro de 2026", "amanhã" ])
      end
    end
  end

  it "Google Agenda do HA casa com a agenda daqui pelo id (a conta é da pessoa; nada é criado)" do
    within(tenant) do
      integration = site.integrations.create!(driver: "calendar", name: "Google Agenda", settings: { "mode" => "google" })
      dev = site.devices.create!(driver: "virtual", external_id: "calendar:#{integration.id}", name: "Agenda", integration: integration)
      agenda = create(:point, site: site, device: dev, name: "Trabalho", key: "agenda_trabalho", capability: "calendar",
                              address: { "calendar" => "teste@empresa.com.br" })
      registry = [ { "entity_id" => "calendar.trabalho", "unique_id" => "teste@gmail.com-teste@empresa.com.br", "platform" => "google" },
                   { "entity_id" => "calendar.birthdays", "unique_id" => "teste@gmail.com-teste@gmail.com-birthdays", "platform" => "google" } ]
      pairs = Integrations::HaServiceEntities.tap(&:reset!).call(site, registry)
      expect(pairs.map { |e, p| [ e["entity_id"], p.id ] }).to eq([ [ "calendar.trabalho", agenda.id ] ])
      expect(site.integrations.count).to eq(1)
    end
  end
end
