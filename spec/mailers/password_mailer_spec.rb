require "rails_helper"

# O e-mail sai no idioma da pessoa; o pt-BR não pode cair no .en do
# `i18n.fallbacks = [:en]` (desenvolvimento e teste).
RSpec.describe PasswordMailer do
  let(:tenant) { Tenant.create!(name: "Teste Mailer", trade_name: "Teste Mailer", city: "Brasília", uf: "DF", ibge_code: "5300108") }

  def user_with(locale)
    User.create!(tenant: tenant, name: "Teste Pessoa", email: "teste-#{locale || 'padrao'}@exemplo.com", password: "12345678", role: "owner",
                 dashboard_prefs: locale ? { "locale" => locale } : {})
  end

  it "pt-BR (padrão) e en, cada um com o próprio texto" do
    pt = described_class.reset(user_with(nil), "tok").text_part.body.to_s
    en = described_class.reset(user_with("en"), "tok").text_part.body.to_s
    expect(pt).to include("Olá, Teste Pessoa.")
    expect(en).to include("Hi, Teste Pessoa.")
  end
end
