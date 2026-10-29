require "rails_helper"

# "Esconder valores": todo dinheiro na tela precisa sair em .money para o CSS borrar.
RSpec.describe ApplicationHelper do
  it "embrulha o valor em .money" do
    expect(helper.money(123_456)).to eq('<span class="money">R$ 1.234,56</span>')
  end

  it "acha os valores dentro de um texto pronto" do
    html = helper.with_money("Fiado vencido: R$ 92,87 de <b>")
    expect(html).to eq('Fiado vencido: <span class="money">R$ 92,87</span> de &lt;b&gt;')
  end

  it "formata documento e telefone guardados só com dígitos" do
    expect(helper.document_text("12345678901")).to eq("123.456.789-01")
    expect(helper.document_text("12345678000195")).to eq("12.345.678/0001-95")
    expect(helper.phone_text("61988887777")).to eq("(61) 98888-7777")
    expect(helper.phone_text("6133334444")).to eq("(61) 3333-4444")
    expect(helper.phone_text(nil)).to be_nil
  end
end
