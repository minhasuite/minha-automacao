require "rails_helper"

RSpec.describe "web/dashboards/widgets/_stat" do
  def render_stat(text) = ApplicationController.render(partial: "web/dashboards/widgets/stat",
                                                       locals: { w: { "label" => "Gasto de hoje", "data" => { "text" => text } }, points: [], dashboard: nil, live: false })

  it "põe a moeda na frente do valor, como no resto das telas" do
    html = render_stat("18,42 R$")
    expect(Nokogiri::HTML(html).css(".ss-kpi-card-value").text.squish).to start_with("R$")
    expect(html).not_to include("18,42 R$")
  end

  it "mantém o texto de outras unidades" do
    expect(Nokogiri::HTML(render_stat("32,7 kWh")).css(".ss-kpi-card-value").text.squish).to eq("32,7 kWh")
  end
end
