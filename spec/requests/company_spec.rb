require "rails_helper"

RSpec.describe "Instalação e convite por link" do
  let(:owner) { create(:user) }
  let(:tenant) { owner.tenant }
  let(:headers) { auth_headers(owner) }
  let(:site) { within(tenant) { create(:site, name: "Casa") } }

  it "mostra e atualiza a instalação (só o dono)" do
    get "/api/v1/company", headers: headers
    expect(data).to include("id" => tenant.id, "plan" => "free", "members_count" => 1)
    patch "/api/v1/company", params: { trade_name: "Casa Boa" }, headers: headers
    expect(data).to include("trade_name" => "Casa Boa")

    member = create(:user, tenant: tenant, role: "member")
    patch "/api/v1/company", params: { name: "X" }, headers: auth_headers(member)
    expect(response).to have_http_status(:forbidden)
  end

  it "o dono gera o link (uso único) e a pessoa se cadastra direto na instalação, com o papel no local" do
    post "/api/v1/company/invites", params: { role: "member", site_id: site.id, site_role: "operator" }, headers: headers
    expect(response).to have_http_status(:created)
    url = data["url"]
    expect(url).to match(%r{/convite/[\w-]{20,}\z})
    path = URI(url).path

    get path
    expect(response.body).to include("Você foi convidado", "Casa")
    post path, params: { name: "Bia", email: "bia@ex.com", password: "1" }
    expect(response).to have_http_status(:unprocessable_content)
    post path, params: { name: "Bia", email: "bia@ex.com", password: "12345678" }
    expect(response).to redirect_to("/")
    bia = User.find_by!(email: "bia@ex.com")
    expect(bia).to have_attributes(tenant_id: tenant.id, role: "member")
    expect(within(tenant) { site.role_for(bia) }).to eq("operator")

    get path
    expect(response).to have_http_status(:not_found)
    expect(response.body).to include("Convite inválido")
    post path, params: { name: "Outro", email: "outro@ex.com", password: "12345678" }
    expect(User.exists?(email: "outro@ex.com")).to be false
  end

  it "entrar em outra empresa não existe mais" do
    post "/api/v1/company/join", params: { code: "X" }, headers: headers
    expect(response).to have_http_status(:not_found)
  end

  it "só o dono convida" do
    admin = create(:user, tenant: tenant, role: "admin")
    post "/api/v1/company/invites", headers: auth_headers(admin)
    expect(response).to have_http_status(:forbidden)
    post "/api/v1/company/invites", params: { role: "owner" }, headers: headers
    expect(data["role"]).to eq("member")
  end
end
