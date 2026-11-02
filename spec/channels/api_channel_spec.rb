require "rails_helper"

# Onda A2 (A17): API WebSocket pelo ApiChannel.
RSpec.describe ApiChannel, type: :channel do
  let(:user) { create(:user, role: "owner") }
  let(:tenant) { user.tenant }
  let!(:site) { within(tenant) { create(:site, name: "Casa") } }
  let!(:lamp) { within(tenant) { create(:point, site: site, device: create(:device, site: site, name: "Sala"), name: "Teste Luz", key: "luz", value: false, writable: true) } }
  let(:seq) { [ 0 ] }

  before do
    stub_connection current_user: user
    subscribe
  end


  def run(type, **fields)
    perform :command, { "id" => (seq[0] += 1), "type" => type }.merge(fields.stringify_keys)
    transmissions.last
  end

  it "responde com id, resultado e erro no formato do HA" do
    expect(run("ping")).to eq("id" => 1, "type" => "result", "success" => true, "result" => "pong")
    expect(run("get_config")["result"]["sites"].map { |s| s["name"] }).to eq([ "Casa" ])
    states = run("get_states", site_id: site.id)["result"]
    expect(states.map { |s| s["name"] }).to eq([ "Teste Luz" ])
    expect(run("get_commands", site_id: site.id)["result"][lamp.id]).to include("on", "off")
    expect(run("render_template", site_id: site.id, template: "{{ 1 | plus: 2 }}")["result"]).to eq("3")
    expect(run("nada")).to include("success" => false, "error" => { "code" => "unknown_command", "message" => "unknown command: nada" })
    expect(run("get_states", site_id: SecureRandom.uuid)["error"]["code"]).to eq("not_found")
  end

  it "comanda o ponto pelo caminho normal e barra quem não pode" do
    allow(Points::Command).to receive(:call).and_return(Struct.new(:id, :status, :error).new("c1", "sent", nil))
    expect(run("call_command", point_id: lamp.id, command: "on")["result"]).to eq("command_id" => "c1", "status" => "sent", "error" => nil)
    expect(Points::Command).to have_received(:call).with(lamp, "on", nil, source: "web", user: user)

    other = within(tenant) { create(:user, tenant: tenant, role: "member") }
    stub_connection current_user: other
    subscribe
    expect(run("call_command", point_id: lamp.id, command: "on")["error"]["code"]).to eq("unauthorized")
  end

  it "assina state_changed e eventos de automação; cancela" do
    expect(run("subscribe_events", site_id: site.id, event_type: "state_changed")["success"]).to be(true)
    expect(subscription).to have_stream_from("#{site.to_gid_param}:points")
    expect(subscription).to have_stream_from("api_events:#{site.id}")
    run("subscribe_events", site_id: site.id, event_type: "teste_evento")

    subscription.send(:point_changed, site.id, %("<turbo-stream action=\\"point_changed\\" target=\\"#{lamp.id}\\"></turbo-stream>"))
    ev = transmissions.last
    expect(ev).to include("id" => 1, "type" => "event")
    expect(ev.dig("event", "event_type")).to eq("state_changed")
    expect(ev.dig("event", "data", "name")).to eq("Teste Luz")

    subscription.send(:deliver, site.id, "teste_evento", WsApi.event("teste_evento", { "x" => 1 }, site.id))
    expect(transmissions.last).to include("id" => 2)
    expect(run("unsubscribe_events", subscription: 2)["success"]).to be(true)
    expect(run("unsubscribe_events", subscription: 2)["error"]["code"]).to eq("not_found")
    expect(run("subscribe_events", site_id: site.id)["success"]).to be(true)
    expect(run("subscribe_events", site_id: site.id, id: 1).dig("error", "message")).to eq("id already in use")

    expect { run("fire_event", site_id: site.id, event_type: "teste_evento", event_data: { "a" => 1 }) }
      .to have_broadcasted_to("api_events:#{site.id}").with(hash_including("event_type" => "teste_evento"))
  end

  it "comando de plugin falso entra pelo registro sem mudar o canal" do
    fake = Class.new(WsApi::Command) do
      describe type: "teste_eco"
      def self.call(ctx, msg) = { "quem" => ctx.user.id, "eco" => msg["texto"] }
    end
    stub_const("WsApi::Commands::TesteEco", fake)
    stub_const("WsApi::COMMANDS", WsApi::COMMANDS + [ "TesteEco" ])
    expect(run("teste_eco", texto: "oi")["result"]).to eq("quem" => user.id, "eco" => "oi")
  end
end
