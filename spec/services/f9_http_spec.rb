require "rails_helper"

RSpec.describe "F9: saída HTTP (SafeHttp) e ação Chamar HTTP" do
  let(:tenant) { create(:tenant) }
  let(:site) { within(tenant) { create(:site, name: "Casa") } }

  around { |ex| ActsAsTenant.with_tenant(tenant) { ex.run } }

  describe SafeHttp do
    it "chama endereço público e segue redirect checando cada salto" do
      stub_request(:get, "https://api.exemplo.com/a").to_return(status: 302, headers: { "Location" => "/b" })
      stub_request(:get, "https://api.exemplo.com/b").to_return(body: "ok")
      res = described_class.get("https://api.exemplo.com/a")
      expect([ res.status, res.body ]).to eq([ 200, "ok" ])
    end

    it "bloqueia IP privado, loopback, link-local e redirect para dentro" do
      %w[http://127.0.0.1/ http://10.0.0.5/ http://192.168.68.199/ http://169.254.169.254/latest http://[::1]/ http://[::ffff:127.0.0.1]/].each do |url|
        expect { described_class.get(url) }.to raise_error(SafeHttp::Blocked), url
      end
      allow(Resolv).to receive(:getaddresses).with("interno.exemplo.com").and_return([ "192.168.1.2" ])
      expect { described_class.get("https://interno.exemplo.com/") }.to raise_error(SafeHttp::Blocked)

      stub_request(:get, "https://api.exemplo.com/r").to_return(status: 301, headers: { "Location" => "http://192.168.68.199/up" })
      expect { described_class.get("https://api.exemplo.com/r") }.to raise_error(SafeHttp::Blocked)
    end

    it "libera endereço interno pela lista da instalação (host ou faixa)" do
      tenant.update!(http_allow_text: "192.168.68.0/24, meu-gestor.local\n")
      expect(tenant.reload.http_allow).to eq([ "192.168.68.0/24", "meu-gestor.local" ])
      stub_request(:post, "http://192.168.68.10/x").to_return(status: 201)
      expect(described_class.request("POST", "http://192.168.68.10/x", body: "{}").status).to eq(201)
      allow(Resolv).to receive(:getaddresses).with("meu-gestor.local").and_return([ "10.1.1.1" ])
      stub_request(:get, "http://meu-gestor.local/").to_return(body: "")
      expect(described_class.get("http://meu-gestor.local/").status).to eq(200)
      expect { described_class.get("http://10.0.0.1/") }.to raise_error(SafeHttp::Blocked)
    end

    it "recusa esquema, método e endereço inválidos e traduz erro de rede" do
      expect { described_class.get("file:///etc/passwd") }.to raise_error(SafeHttp::Error, /http/)
      expect { described_class.request("TRACE", "https://a.com") }.to raise_error(SafeHttp::Error, /Método/)
      expect { described_class.get("http://exa mple.com") }.to raise_error(SafeHttp::Error)
      allow(Resolv).to receive(:getaddresses).with("nada.invalid").and_return([])
      expect { described_class.get("https://nada.invalid/") }.to raise_error(SafeHttp::Error, /Não achei/)
      stub_request(:get, "https://lento.com/").to_timeout
      expect { described_class.get("https://lento.com/") }.to raise_error(SafeHttp::Error, /Falha/)
      stub_request(:get, "https://loop.com/").to_return(status: 302, headers: { "Location" => "https://loop.com/" })
      expect { described_class.get("https://loop.com/") }.to raise_error(SafeHttp::Error, /Redirecionamentos/)
    end
  end

  describe "ação http" do
    let(:definition) do
      { "triggers" => [ { "type" => "manual" } ],
        "actions" => [ { "type" => "http", "method" => "POST", "url" => "https://vendas.exemplo.com/hook?site={{ site.name }}",
                         "headers" => "Authorization: Bearer {{ secret }}\nContent-Type: application/json\nlinha ruim",
                         "secret" => "tok-123", "body" => "{\"msg\": \"{{ trigger.title }}\"}", "timeout" => 5 } ] }
    end

    it "valida, cifra o segredo ao salvar e chama com o segredo só no pedido" do
      expect(Automations::ActionTypes.keys).to include("http")
      expect(Automations::Dsl.errors(definition, site)).to be_empty
      bad = definition.deep_dup.tap { |d| d["actions"][0].merge!("timeout" => 99, "method" => "TRACE") }
      expect(Automations::Dsl.errors(bad, site).join).to include("opção inválida", "tempo limite de 1 a 30")

      a = Automation.create!(site: site, name: "Avisar vendas")
      a.publish!(definition)
      stored = a.reload.definition["actions"][0]["secret"]
      expect(stored).to be_a(Hash)
      expect(stored.to_json).not_to include("tok-123")
      expect(Automations::Dsl.decrypt_secret(stored)).to eq("tok-123")

      hook = stub_request(:post, "https://vendas.exemplo.com/hook?site=Casa")
             .with(headers: { "Authorization" => "Bearer tok-123", "Content-Type" => "application/json" }, body: "{\"msg\": \"Teste\"}")
             .to_return(status: 200, body: "{\"ok\":true}")
      run = a.fire!({ "type" => "manual", "title" => "Teste" }, skip_conditions: true)
      expect(hook).to have_been_requested
      expect(run.status).to eq("done")
      expect(run.steps.last).to include("title" => "Chamar POST vendas.exemplo.com", "result" => "ok")
      expect(run.state["vars"]).to include("http_status" => 200)
      expect(run.state["vars"]).not_to have_key("secret")
      expect(run.to_json).not_to include("tok-123")
    end

    it "falha com status de erro, endereço interno e não envia na simulação" do
      a = Automation.create!(site: site, name: "X")
      a.publish!(definition)
      stub_request(:post, /vendas/).to_return(status: 500)
      expect(a.fire!({ "type" => "manual", "title" => "T" }, skip_conditions: true)).to have_attributes(status: "failed", error: /respondeu 500/)

      a.publish!(definition.deep_dup.tap { |d| d["actions"][0]["url"] = "http://192.168.68.199/up" })
      expect(a.fire!({ "type" => "manual", "title" => "T" }, skip_conditions: true).error).to include("Endereço interno bloqueado")

      sim = a.simulate!
      expect(sim.steps.last).to include("result" => "simulated")
    end

    it "editor: segredo vazio mantém o guardado; resumo não mostra o segredo" do
      editor = Automations::Editor.new(Automations::Dsl.empty, site)
      path = editor.add("actions", "http")
      editor.update(path, { "url" => "https://a.com", "secret" => "s1" })
      node = Automations::Dsl.normalize(editor.definition, site)["actions"][0]
      expect(node["secret"]).to be_a(Hash)
      editor2 = Automations::Editor.new({ "actions" => [ node ] }, site)
      editor2.update("actions.0", { "url" => "https://b.com", "secret" => "" })
      expect(editor2.definition["actions"][0]["secret"]).to eq(node["secret"])
      spec = Automations::ActionTypes["http"]
      summary = ApplicationController.helpers.block_summary(node, spec, {})
      expect(summary).to include("guardado")
      expect(summary).not_to include("s1")
      expect(Automations::Dsl.decrypt_secret({ "enc" => "lixo" })).to be_nil
    end
  end
end
