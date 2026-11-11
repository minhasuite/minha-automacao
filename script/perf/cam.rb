# Quadro de câmera fora do ar (go2rtc num IP que não responde): tempo de cada pedido,
# com a espera da falha vencendo entre as rodadas (como acontece a cada FAIL_HOLD).
require "benchmark"
ENV["GO2RTC_URL"] = "http://10.255.255.1:1984"
ActionController::Base.allow_forgery_protection = false
ActiveRecord::Base.logger = nil
user = User.find_by!(email: "teste@teste.com")
cam = Rails.application.executor.wrap do
  ActsAsTenant.with_tenant(user.tenant) do
    site = Site.find_by!(name: "Casa grande")
    d = site.devices.find_by(name: "Câmera fora") || site.devices.create!(name: "Câmera fora", driver: "go2rtc", address: { "host" => "10.255.255.2" })
    d.points.first || d.points.create!(site: site, name: "Canal", capability: "stream", history: "none", address: { "path" => "/live" })
  end
end
s = ActionDispatch::Integration::Session.new(Rails.application)
s.host! "localhost"
s.post "/entrar", params: { email: user.email, password: "12345678" }
Rails.cache.clear
4.times do |round|
  t = Array.new(3) { Benchmark.realtime { s.get "/cameras/#{cam.id}/quadro" } * 1000 }
  printf("rodada %d (espera da falha vencida): %s ms  status %d\n", round + 1, t.map { |x| x.round }.join(" / "), s.response.status)
  Rails.cache.delete("go2rtc:falha:#{cam.id}")
end
