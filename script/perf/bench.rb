# Mede o painel grande: tela inteira, recarga de widget (área e tile) e o Resolver.
# uso: bin/rails runner script/perf/bench.rb [n]
require "benchmark"
n = (ARGV[0] || 15).to_i
ActionController::Base.allow_forgery_protection = false
Rails.logger.level = :warn
ActiveRecord::Base.logger = nil
user = User.find_by!(email: "teste@teste.com")
site = ActsAsTenant.with_tenant(user.tenant) { Site.find_by!(name: "Casa grande") }
dash = ActsAsTenant.with_tenant(user.tenant) { site.dashboards.find_by!(name: "Grande") }
ws = ActsAsTenant.with_tenant(user.tenant) { Dashboards::Resolver.flatten(dash.published["views"].flat_map { |v| Array(v["sections"]).flat_map { |s| s["widgets"] } + Array(v["badges"]) }) }
pick = { "area_card" => ws.find { |w| w["type"] == "area_card" }["id"], "tile" => ws.find { |w| w["type"] == "tile" }["id"],
         "stat(badge)" => ws.find { |w| w["type"] == "stat" }["id"], "query_list" => ws.find { |w| w["type"] == "query_list" }["id"] }
s = ActionDispatch::Integration::Session.new(Rails.application)
s.host! "localhost"
s.post "/entrar", params: { email: user.email, password: "12345678" }
$q = 0
ActiveSupport::Notifications.subscribe("sql.active_record") { |*, p| $q += 1 unless p[:name] == "SCHEMA" || p[:cached] }
stat = ->(label, &blk) {
  blk.call; blk.call # aquece
  $q = 0
  t = Array.new(n) { Benchmark.realtime(&blk) * 1000 }.sort
  printf("%-28s p50 %7.1f ms  média %7.1f  pior %7.1f  SQL/pedido %5.1f\n", label, t[t.size / 2], t.sum / t.size, t.last, $q.to_f / n)
}
stat.call("GET /paineis/:id") { s.get "/paineis/#{dash.id}"; raise "#{s.response.status} #{s.response.location}" unless s.response.status == 200 }
pw = Rails.application.executor.wrap { ActsAsTenant.with_tenant(user.tenant) { site.points.find_by!(device_class: "power").id } }
bump = -> { Rails.application.executor.wrap { ActsAsTenant.without_tenant { Point.where(id: pw).update_all(value: rand(1000.0)) } } }
stat.call("GET /paineis/:id (ponto mudou)") { bump.call; s.get "/paineis/#{dash.id}" }
stat.call("GET /w/ area_card (ponto mudou)") { bump.call; s.get "/paineis/#{dash.id}/w/#{pick['area_card']}" }
pick.each do |k, id|
  stat.call("GET /w/ #{k}") { s.get "/paineis/#{dash.id}/w/#{id}", headers: { "Turbo-Frame" => "w-#{id}" }; raise "#{k} #{s.response.status}" unless s.response.status == 200 }
end
Rails.application.executor.wrap { ActsAsTenant.with_tenant(user.tenant) do
  stat.call("Resolver#call (painel)") { Dashboards::Resolver.new(dash.reload, role: "owner").call }
  stat.call("Resolver#widget area_card") { Dashboards::Resolver.new(dash, role: "owner").then { |r| r.widget(pick["area_card"]); r.points_payload } }
end }
