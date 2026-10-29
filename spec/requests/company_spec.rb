require "rails_helper"

RSpec.describe "Empresa e convites" do
  let(:owner) { create(:user) }
  let(:tenant) { owner.tenant }
  let(:headers) { auth_headers(owner) }

  it "mostra e atualiza a empresa (só o dono)" do
    get "/api/v1/company", headers: headers
    expect(data).to include("id" => tenant.id, "plan" => "free", "members_count" => 1)
    patch "/api/v1/company", params: { trade_name: "Casa Boa", uf: "go", ibge_code: "5208707" }, headers: headers
    expect(data).to include("trade_name" => "Casa Boa", "uf" => "GO", "ibge_code" => "5208707")

    member = create(:user, tenant: tenant, role: "member")
    patch "/api/v1/company", params: { name: "X" }, headers: auth_headers(member)
    expect(response).to have_http_status(:forbidden)
  end

  it "convida com papel e entra com o código (uso único)" do
    post "/api/v1/company/invites", params: { role: "admin" }, headers: headers
    expect(response).to have_http_status(:created)
    code = data["code"]
    newcomer = create(:user)
    old = newcomer.tenant_id
    post "/api/v1/company/join", params: { code: code }, headers: auth_headers(newcomer)
    expect(data["id"]).to eq(tenant.id)
    expect(newcomer.reload).to have_attributes(tenant_id: tenant.id, role: "admin")
    expect(Tenant.exists?(old)).to be false
    post "/api/v1/company/join", params: { code: code }, headers: auth_headers(create(:user))
    expect(json.dig("error", "code")).to eq("invalid_invite")
    post "/api/v1/company/join", params: { code: "X" }, headers: auth_headers(newcomer)
    expect(json.dig("error", "code")).to eq("invalid_invite")
  end

  it "quem já é da empresa não entra de novo" do
    post "/api/v1/company/invites", headers: headers
    post "/api/v1/company/join", params: { code: data["code"] }, headers: headers
    expect(json.dig("error", "code")).to eq("already_member")
  end

  it "quem tem dados na empresa atual precisa confirmar o descarte" do
    post "/api/v1/company/invites", headers: headers
    code = data["code"]
    other = create(:user)
    within(other.tenant) { create(:notification) }
    post "/api/v1/company/join", params: { code: code }, headers: auth_headers(other)
    expect(response).to have_http_status(:conflict)
    old = other.tenant_id
    post "/api/v1/company/join", params: { code: code, discard_current: true }, headers: auth_headers(other)
    expect(response).to have_http_status(:ok)
    expect(other.reload.role).to eq("member")
    expect(Tenant.exists?(old)).to be false
  end

  it "membro não convida; administrador não convida administrador" do
    admin = create(:user, tenant: tenant, role: "admin")
    post "/api/v1/company/invites", params: { role: "admin" }, headers: auth_headers(admin)
    expect(response).to have_http_status(:forbidden)
    post "/api/v1/company/invites", headers: auth_headers(admin)
    expect(response).to have_http_status(:created)
    member = create(:user, tenant: tenant, role: "member")
    post "/api/v1/company/invites", headers: auth_headers(member)
    expect(response).to have_http_status(:forbidden)
  end
end
