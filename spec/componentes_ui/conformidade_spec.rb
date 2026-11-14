require "rails_helper"
require "componentes_ui/conformidade"

RSpec.describe ComponentesUi::Conformidade do
  it "o web é 100% componentes_ui" do
    problemas = described_class.verificar(Rails.root)
    expect(problemas).to be_empty, problemas.join("\n")
  end
end
