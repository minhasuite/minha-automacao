namespace :perf do
  # Banco de dev parecido com a casa (para medir o painel, docs/desempenho.md):
  # um local "Casa Perf" com 10 cômodos, ~500 pontos e o painel automático
  # publicado (Início + uma visão por cômodo = 11 visões). Só em dev.
  #   bin/rails perf:seed_paineis
  desc "Cria o local 'Casa Perf' com ~500 pontos e um painel de 11 visões (só dev)"
  task seed_paineis: :environment do
    abort "só em desenvolvimento" unless Rails.env.development?

    user = User.find_by!(email: "teste@teste.com")
    ActsAsTenant.with_tenant(user.tenant) do
      Site.where(name: "Casa Perf").find_each(&:destroy!)
      site = Site.create!(name: "Casa Perf", timezone: "America/Sao_Paulo")
      SiteMembership.find_or_create_by!(site: site, user: user) { |m| m.role = "owner" }
      rooms = %w[Sala Cozinha Quarto Suíte Escritório Varanda Garagem Lavanderia Jardim Piscina]
      kinds = [ [ "Luz", "onoff", nil ], [ "Luz dimerizável", "dimmer", nil ], [ "Tomada", "onoff", nil ], [ "Porta", "contact", nil ],
                [ "Movimento", "motion", nil ], [ "Temperatura", "measure", "°C" ], [ "Potência", "measure", "W" ], [ "Umidade", "measure", "%" ] ]
      n = 0
      rooms.each_with_index do |room, ri|
        area = site.areas.create!(name: room, position: ri)
        6.times do |di|
          device = site.devices.create!(name: "#{room} aparelho #{di + 1}", area: area, driver: "virtual")
          kinds.each do |label, cap, unit|
            n += 1
            value = case cap
            when "onoff", "contact", "motion" then n.even?
            when "dimmer" then n % 100
            else (n % 37) + 0.5
            end
            device.points.create!(site: site, name: "#{label} #{room} #{di + 1}", capability: cap, unit: unit, writable: %w[onoff dimmer].include?(cap),
                                  value: value, quality: "good", changed_at: Time.current, **(cap == "dimmer" ? { min: 0, max: 100 } : {}))
          end
        end
      end
      # Como a casa: automações e scripts viram pontos (tiles), cenas na barra.
      20.times { |i| site.automations.create!(name: "Automação #{i + 1}", enabled: false) }
      light = site.points.find_by!(capability: "onoff")
      6.times { |i| site.scenes.create!(name: "Cena #{i + 1}", items: [ { "point_id" => light.id, "command" => "on" } ]) }
      definition = Dashboards::Generator.call(site)
      # Início como o importado do HA: cartão por cômodo (modelo e nativo), contagens e os tiles das automações.
      areas = site.areas.order(:position).to_a
      extra = [
        *areas.map { |a| { "id" => "perf-ac-#{a.id}", "type" => "area_card", "area" => a.id } },
        *areas.map { |a| { "id" => "perf-tp-#{a.id}", "type" => "template", "template" => "area", "vars" => { "area" => a.id } } },
        *%w[onoff contact motion].map { |c| { "id" => "perf-st-#{c}", "type" => "stat", "label" => c, "query" => { "capability" => c, "state" => "on" } } },
        { "id" => "perf-scenes", "type" => "scene_bar" },
        *site.points.where("address ? 'automation_id'").map { |p| { "id" => "perf-au-#{p.id}", "type" => "tile", "bind" => p.id } }
      ]
      definition["views"].first["sections"].unshift({ "id" => "perf-home", "title" => "Casa", "widgets" => extra })
      # O Schema aceita até 400 widgets: corta cada visão de cômodo por igual (a casa tem ~350).
      definition["views"].each_with_index do |v, i|
        budget = i.zero? ? 120 : 24
        v["badges"] = Array(v["badges"]).first(4)
        v["sections"].each { |s| s["widgets"] = s["widgets"].first([ budget, 0 ].max).tap { |kept| budget -= kept.size } }
      end
      dashboard = site.dashboards.create!(name: "Casa", kind: "custom", site_default: true, definition: definition)
      dashboard.publish!(definition)
      puts "Casa Perf: #{site.points.count} pontos, #{definition['views'].size} visões, painel #{dashboard.id}"
    end
  end

  # Mede o painel padrão da "Casa Perf" (frio = sem cache): tempo e consultas.
  #   bin/rails perf:painel
  desc "Mede a resolução do painel da Casa Perf (frio, por visão e inteiro)"
  task painel: :environment do
    user = User.find_by!(email: "teste@teste.com")
    ActsAsTenant.with_tenant(user.tenant) do
      site = Site.find_by!(name: "Casa Perf")
      dashboard = site.dashboards.find_by!(name: "Casa")
      count = 0
      counter = ->(*, payload) { count += 1 unless payload[:name] == "SCHEMA" || payload[:cached] }
      measure = lambda do |label, &blk|
        times = []
        queries = 0
        5.times do
          Dashboards::Cache.clear!
          count = 0
          ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
            t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            blk.call
            times << (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0)
          end
          queries = count
        end
        puts format("%-34s mediana %7.1f ms  mínimo %7.1f ms  %4d consultas", label, times.sort[2] * 1000, times.min * 1000, queries)
      end
      measure.("inteiro (#{dashboard.published["views"].size} visões, frio)") { Dashboards::Resolver.new(dashboard, role: "owner").call }
      if Dashboards::Resolver.instance_method(:initialize).parameters.any? { |_, name| name == :only_view }
        measure.("só a visão aberta (frio)") { Dashboards::Resolver.new(dashboard, role: "owner", only_view: :open).call }
        measure.("outra visão sob demanda (frio)") { Dashboards::Resolver.new(dashboard, role: "owner", only_view: dashboard.published["views"].last["id"]).call }
      end
      # Pré-aquecido: o job já deixou no cache comum; o processo da web (memória vazia) só lê.
      Dashboards::Prewarm.run(site)
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Dashboards::Cache::STORE.clear
      Dashboards::Cache.resolved(dashboard, role: "owner", lazy: true)
      puts format("%-34s %7.1f ms", "visão aberta pré-aquecida", (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000)
      measure.("um widget (frio)") { Dashboards::Resolver.new(dashboard, role: "owner").widget(dashboard.published["views"].first["sections"].first["widgets"].first["id"]) }
    end
  end
end
