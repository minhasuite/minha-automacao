require "rails_helper"

# Condições conferidas na execução: a árvore do Ss::TreeViewComponent.
RSpec.describe AutomationsHelper do
  it "monta os nós com ✓/✗, valores e os grupos abertos com os filhos" do
    nodes = helper.run_check_nodes([ { "label" => "Todas", "result" => false, "children" => [
      { "label" => "Sala > 25 °C", "result" => true, "values" => "26,1 °C" },
      { "label" => "Porta fechada", "result" => false, "values" => "" }
    ] } ])
    expect(nodes.size).to eq(1)
    expect(nodes[0]).to include(open: true)
    expect(nodes[0][:label]).to include("text-danger", "Todas")
    expect(nodes[0][:children].map { _1[:value] }).to eq([ "26,1 °C", nil ])
    expect(nodes[0][:children][0][:label]).to include("text-success", "Sala &gt; 25 °C")
    expect(nodes[0][:children][1]).not_to have_key(:children)
    html = helper.render(Ss::TreeViewComponent.new(label: "Condições", nodes: nodes))
    expect(html).to include("ss-tree", "<details open", "26,1 °C")
  end
end
