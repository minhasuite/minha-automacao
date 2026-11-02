require "rails_helper"

# Produto: pt-BR, en e es com as mesmas chaves (config/locales/*.yml), e o
# idioma da tela escolhido pela pessoa, pelo cookie ou pelo navegador.
RSpec.describe "Idiomas", type: :request do
  def flat(hash, prefix = nil)
    hash.flat_map { |k, v| v.is_a?(Hash) && !(v.keys - %w[zero one other]).empty? ? flat(v, [ prefix, k ].compact.join(".")) : [ [ prefix, k ].compact.join(".") ] }
  end

  let(:keys) do
    Dir[Rails.root.join("config/locales/*.yml")].each_with_object(Hash.new { |h, k| h[k] = [] }) do |file, acc|
      YAML.load_file(file).each { |locale, tree| acc[locale] += flat(tree) }
    end
  end

  it "pt-BR, en e es têm exatamente as mesmas chaves" do
    expect(keys.keys).to contain_exactly("pt-BR", "en", "es")
    base = keys["pt-BR"].sort
    expect(base.size).to be > 300
    %w[en es].each do |loc|
      expect(keys[loc].sort - base).to eq([]), "#{loc} sobrando"
      expect(base - keys[loc].sort).to eq([]), "#{loc} faltando"
    end
  end

  it "plural com as mesmas formas e interpolação igual nos três" do
    tree = %w[pt-BR en es].to_h { |l| [ l, Dir[Rails.root.join("config/locales/*.yml")].map { |f| YAML.load_file(f)[l] || {} }.reduce({}, :deep_merge) ] }
    vars = ->(s) { s.to_s.scan(/%\{(\w+)\}/).flatten.sort }
    keys["pt-BR"].each do |k|
      pt = tree["pt-BR"].dig(*k.split("."))
      %w[en es].each do |l|
        other = tree[l].dig(*k.split("."))
        if pt.is_a?(Hash)
          expect(other.keys).to eq(pt.keys), "#{l}.#{k}"
        else
          expect(vars.(other)).to eq(vars.(pt)), "#{l}.#{k}"
        end
      end
    end
  end

  it "o idioma vem do navegador quando ninguém escolheu" do
    expect(Localized.from_header("en-US,en;q=0.9,pt;q=0.8")).to eq("en")
    expect(Localized.from_header("es-AR,es;q=0.9")).to eq("es")
    expect(Localized.from_header("pt-PT,pt;q=0.9")).to eq("pt-BR")
    expect(Localized.from_header("fr-FR,de")).to be_nil
    expect(Localized.from_header(nil)).to be_nil
  end

  describe "nas telas" do
    let(:owner) { create(:user, email: "dono@ex.com") }

    it "a tela de entrar segue o navegador e o seletor grava a escolha" do
      owner
      get "/entrar", headers: { "Accept-Language" => "en-US,en;q=0.9" }
      expect(response.body).to include("Welcome back", 'lang="en"', "Create a free account")
      get "/entrar", headers: { "Accept-Language" => "es-ES" }
      expect(response.body).to include("Bienvenido de nuevo")

      patch "/idioma", params: { locale: "es" }, headers: { "HTTP_REFERER" => "/entrar" }
      expect(cookies[:ma_locale]).to eq("es")
      get "/entrar"
      expect(response.body).to include("Bienvenido de nuevo")
      patch "/idioma", params: { locale: "xx" }
      expect(cookies[:ma_locale]).to eq("es")
    end

    it "a escolha da pessoa vale em qualquer navegador; telas principais em inglês" do
      site = within(owner.tenant) { create(:site, name: "Casa") }
      within(owner.tenant) { create(:device, site: site, name: "Teste Lâmpada") }
      Onboarding.finish!(owner.tenant)
      post "/entrar", params: { email: owner.email, password: "12345678" }
      patch "/idioma", params: { locale: "en" }
      expect(owner.reload.dashboard_prefs["locale"]).to eq("en")
      cookies.delete(:ma_locale)

      get "/", headers: { "Accept-Language" => "pt-BR" }
      expect(response.body).to include("Places", "Notifications", "Settings", 'lang="en"')
      get "/locais/#{site.id}/dispositivos"
      expect(response.body).to include("Devices", "Maker / model", "Teste Lâmpada")
      get "/locais/#{site.id}/paineis"
      expect(response.body).to include("Dashboards", "Open on my Home")
      get "/configuracoes/sistema"
      expect(response.body).to include("Updates", "Installed version", "Installation shadow mode")
      get "/configuracoes/conta"
      expect(response.body).to include("My account", "Language")
    end
  end
end
