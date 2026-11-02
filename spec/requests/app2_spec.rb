require "rails_helper"

# app2 (app que vende pela experiência): o que o app 0.2 pede do servidor —
# botão do aviso que comanda um ponto, aviso com progresso, anúncio mDNS,
# pontos do local para widgets/atalhos/controles do Android e a definição do
# painel com o catálogo de widgets para o editor do app.
RSpec.describe "API do app 0.2 (app2)" do
  let(:owner) { create(:user, name: "Dona") }
  let(:tenant) { owner.tenant }
  let(:headers) { auth_headers(owner) }
  let!(:site) { within(tenant) { create(:site, name: "Casa") } }
  let(:device) { within(tenant) { create(:device, site: site, name: "Teste Virtual", driver: "virtual") } }
  let!(:lamp) { within(tenant) { create(:point, device: device, site: site, key: "sala.luz", name: "Luz", capability: "onoff", writable: true, value: false) } }
  let!(:gate) { within(tenant) { create(:point, device: device, site: site, key: "garagem.portao", name: "Portão", capability: "onoff", writable: true, value: false, risk: "critical") } }

  def member(role)
    user = create(:user, tenant: tenant, role: "member", name: "Visita")
    within(tenant) { create(:site_membership, site: site, user: user, role: role) }
    user
  end

  def automation(definition)
    within(tenant) { Automation.create!(site: site, name: "Teste #{SecureRandom.hex(3)}").tap { |a| a.publish!(definition) && a.update!(enabled: true) } }
  end

  describe "botão do aviso que comanda um ponto" do
    it "o editor lê 'id: Título -> ponto comando'; a resposta manda o comando como a pessoa" do
      buttons = Automations::Editor.new({}, site).send(:buttons, "ligar: Ligar a luz -> sala.luz on\nnao: Agora não")
      expect(buttons).to eq([ { "id" => "ligar", "title" => "Ligar a luz", "point" => "sala.luz", "command" => "on" }, { "id" => "nao", "title" => "Agora não" } ])

      a = automation({ "triggers" => [ { "type" => "manual" } ],
                       "actions" => [ { "type" => "notify", "channels" => [ "in_app" ], "to" => "user:#{owner.id}", "title" => "Esqueceu a luz?", "buttons" => buttons } ] })
      within(tenant) { a.fire!({ "type" => "manual" }) }
      n = within(tenant) { Notification.find_by!(title: "Esqueceu a luz?") }
      expect(n.actions.first).to include("point_id" => lamp.id, "command" => "on")
      expect(n.actions.first).not_to have_key("point")

      post "/push/resposta", params: { token: n.action_token(owner), action_id: "ligar" }
      expect(response).to have_http_status(:no_content)
      cmd = within(tenant) { Command.sole }
      expect([ cmd.source, cmd.user_id, lamp.reload.value ]).to eq([ "push", owner.id, true ])
    end

    it "sem permissão para o risco do ponto, a resposta vale mas o comando não sai" do
      guest = member("guest")
      n = within(tenant) do
        Notification.create!(kind: "aviso", title: "Portão", user: guest,
                             data: { "site_id" => site.id, "actions" => [ { "id" => "abrir", "title" => "Abrir", "point_id" => gate.id, "command" => "on" } ] })
      end
      post "/push/resposta", params: { token: n.action_token(guest), action_id: "abrir" }
      expect(response).to have_http_status(:no_content)
      expect(within(tenant) { [ Command.count, n.reload.responded_at.present? ] }).to eq([ 0, true ])
    end

    it "botão com comando sem ponto não publica" do
      expect do
        automation({ "triggers" => [ { "type" => "manual" } ],
                     "actions" => [ { "type" => "notify", "title" => "x", "buttons" => [ { "id" => "a", "title" => "A", "command" => "on" } ] } ] })
      end.to raise_error(ActiveRecord::RecordInvalid, /ponto e comando/)
    end
  end

  describe "aviso com progresso" do
    it "a ação Avisar renderiza o progresso de um ponto; o FCM leva e o Web Push corta" do
      within(tenant) { create(:point, device: device, site: site, key: "robo.progresso", name: "Progresso", capability: "measure", value: 42.6) }
      a = automation({ "triggers" => [ { "type" => "manual" } ],
                       "actions" => [ { "type" => "notify", "channels" => [ "in_app" ], "title" => "Limpando", "tag" => "robo",
                                        "progress" => %({{ points["robo.progresso"].value }}) } ] })
      within(tenant) { a.fire!({ "type" => "manual" }) }
      n = within(tenant) { Notification.find_by!(title: "Limpando") }
      expect(n.data["progress"]).to eq(43)
      expect(Push::Message.new(n, owner).to_h(Push::Fcm.capabilities)["data"]).to include("progress" => 43)
      expect(Push::Message.new(n, owner).to_h(Push::Browser.capabilities)["data"]).not_to have_key("progress")
      expect(Automations::ActionTypes::NotifyAction.progress("abc")).to be_nil
      expect(Automations::ActionTypes::NotifyAction.progress("130")).to eq(100)
    end

    it "transporte falso registrado sem :progress não recebe a barra (sem mudar o núcleo)" do
      got = []
      fake = Module.new do
        define_singleton_method(:configured?) { true }
        define_singleton_method(:capabilities) { Notifier::FEATURES - %i[progress] }
        define_singleton_method(:deliver) { |_user, message| got << message.to_h(capabilities) }
        define_singleton_method(:clear) { |_user, _tag| nil }
      end
      stub_const("Push::Falso", fake)
      stub_const("Push::TRANSPORTS", %w[Falso])
      n = within(tenant) { Notifier.notify!(kind: "aviso", title: "Ciclo", user: owner, push: false, data: { "progress" => 10, "tag" => "maquina" }) }
      Push.deliver(n)
      expect(got.sole).to include("title" => "Ciclo", "tag" => "maquina")
      expect(got.sole["data"]).not_to have_key("progress")
    end
  end

  describe "anúncio mDNS do servidor" do
    it "responde a pergunta pelo serviço com PTR, SRV, TXT e A; ignora outras" do
      reply = Mdns.answer(Mdns.query(Mdns::SERVICE), name: "Teste Casa", ip: "192.168.0.10", port: 8080, txt: { "path" => "/" })
      found = Mdns.parse(Mdns::SERVICE, reply, "10.0.0.1")
      expect(found).to eq([ { "name" => "Teste Casa", "host" => "192.168.0.10", "port" => 8080, "txt" => { "path" => "/" } } ])
      expect(Mdns.answer(Mdns.query("_esphomelib._tcp.local"), name: "x", ip: "192.168.0.10", port: 80)).to be_nil
      expect(Mdns.answer("lixo", name: "x", ip: "192.168.0.10", port: 80)).to be_nil
    end
  end

  describe "pontos do local para widgets, atalhos e controles" do
    it "lista como o app desenha; commandable corta pelo papel; um ponto com ?view=app" do
      get "/api/v1/sites/#{site.id}/points", params: { view: "app", commandable: 1 }, headers: auth_headers(member("guest"))
      expect(data.pluck("name")).to eq([ "Luz" ])
      get "/api/v1/sites/#{site.id}/points", params: { view: "app" }, headers: headers
      expect(data.pluck("name")).to contain_exactly("Luz", "Portão")
      get "/api/v1/points/#{gate.id}", params: { view: "app" }, headers: headers
      expect(data).to include("title" => be_present, "on" => false, "risk" => "critical", "can_command" => true, "commands" => include("toggle"))
    end
  end

  describe "editor do painel no app" do
    it "definição em edição e o catálogo dos plugins (um falso entra sem mudar o núcleo); só quem gerencia" do
      fake = Class.new(Dashboards::Widgets::Base) { describe type: "teste_falso", label: "Teste falso", icon: "star", bind: true, required: %w[bind] }
      stub_const("Dashboards::Widgets::TesteFalso", fake)
      stub_const("Dashboards::Widgets::PLUGINS", Dashboards::Widgets::PLUGINS + %w[TesteFalso])
      d = within(tenant) { Dashboard.ensure_for(site).first }

      get "/api/v1/dashboards/#{d.id}/definition", headers: headers
      expect(data["definition"]).to include("views")
      expect(json["meta"]["catalog"]).to include(include("type" => "teste_falso", "label" => "Teste falso", "bind" => true, "required" => [ "bind" ]))

      get "/api/v1/dashboards/#{d.id}/definition", headers: auth_headers(member("guest"))
      expect(response).to have_http_status(:forbidden)
    end
  end
end
