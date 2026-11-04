require "rails_helper"

# Migração W1 para a gem componentes_ui: a confirmação é o Ss::ConfirmDialogComponent
# (global, no layout), a ação perigosa leva o tom "danger" e o verbo no botão, e o
# icon("nome") do produto serve nos parâmetros de SVG dos componentes.
RSpec.describe "componentes_ui", type: :request do
  let(:user) { create(:user) }
  let(:site) { within(user.tenant) { create(:site, name: "Casa") } }

  before do
    Onboarding.finish!(user.tenant)
    post "/entrar", params: { email: user.email, password: "12345678" }
  end

  it "o layout traz a caixa de confirmação da gem e excluir o local pede o tom de perigo" do
    get "/locais/#{site.id}/editar"
    expect(response.body).to include('data-controller="ss-confirm-dialog"', 'id="confirm"', "Tem certeza?")
    form = Nokogiri::HTML(response.body).at_css("form[action='/locais/#{site.id}'] [name=_method][value=delete]").parent
    expect(form["data-turbo-confirm-tone"]).to eq("danger")
    expect(form["data-turbo-confirm-button"]).to eq("Excluir")
    expect(form["data-turbo-confirm"]).to include("Casa")
  end

  it "os controllers ss-* da gem entram no importmap" do
    get "/locais"
    expect(response.body).to include("componentes_ui/controllers/ss_confirm_dialog_controller")
  end

  it "icon(...) vai direto no icon: de um componente" do
    html = ApplicationController.render(Ss::CollapsibleComponent.new(title: "Sala", icon: ApplicationController.helpers.icon("home", "")), layout: false)
    expect(html).to include("ss-collapse-ico", 'data-icon="home"', "<svg")
    expect(html).not_to include("&lt;svg")
  end
end
