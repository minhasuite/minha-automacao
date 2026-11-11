# Painel grande de teste (~500 pontos) para medir o desempenho. Idempotente pelo nome do local.
user = User.find_by!(email: "teste@teste.com")
ActsAsTenant.with_tenant(user.tenant) do
  site = Site.find_by(name: "Casa grande") || Site.create!(name: "Casa grande")
  if site.points.count < 500
    10.times do |a|
      area = site.areas.create!(name: "Cômodo #{a + 1}")
      10.times do |d|
        dev = site.devices.create!(name: "Tomada #{a + 1} #{d + 1}", area: area, driver: "virtual")
        dev.points.create!(site: site, name: "Ligada", capability: "onoff", value: d.even?)
        dev.points.create!(site: site, name: "Potência", capability: "measure", unit: "W", device_class: "power", value: rand(0.0..1500.0).round(1))
        dev.points.create!(site: site, name: "Tensão", capability: "measure", unit: "V", device_class: "voltage", value: rand(215.0..225.0).round(1))
        dev.points.create!(site: site, name: "Porta", capability: "contact", value: false)
        dev.points.create!(site: site, name: "Movimento", capability: "motion", value: false)
      end
    end
  end
  SiteMembership.find_or_create_by!(site: site, user: user) { |m| m.role = "owner" }
  defn = Dashboards::Generator.call(site)
  defn["views"][1..].each { |v| v["sections"] = v["sections"].first(5) }
  defn["views"][0]["sections"].each { |s| s["widgets"] = s["widgets"].first(40) }
  dash = site.dashboards.find_by(name: "Grande") || site.dashboards.create!(name: "Grande", kind: "home", site_default: false, definition: defn)
  dash.publish!(defn) if dash.version.to_i < 1
  w = Dashboards::Resolver.flatten(dash.published["views"].flat_map { |v| Array(v["sections"]).flat_map { |s| s["widgets"] } })
  puts({ site: site.id, dashboard: dash.id, points: site.points.count, widgets: w.size,
         area_card: w.find { |x| x["type"] == "area_card" }&.dig("id"), tile: w.find { |x| x["type"] == "tile" }&.dig("id") }.to_json)
end
