require "open3"

# Régua do CSS do produto (bin/conferir-css): só classes de domínio nas telas e nos CSS de tela;
# peça genérica (card, título, texto, ícone, botão, chip, linha, selo, barra, amostra de tema) é da gem.
RSpec.describe "CSS do produto" do
  it "só tem classes de domínio, sem regra em cima de classe da gem" do
    out, status = Open3.capture2e(Rails.root.join("bin/conferir-css").to_s)
    expect(status).to be_success, out
    expect(out).to include("0 genéricas")
  end
end
