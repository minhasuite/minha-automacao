namespace :dashboards do
  # Arruma as visões de cômodo (as com `area`) do painel: selos no topo e
  # colunas ações · cenas e automações · mídia (Dashboards::RoomLayout).
  # Sem PUBLICAR=1 só mostra o antes → depois.
  #   bin/rails 'dashboards:comodos[<id do painel>]'
  #   PUBLICAR=1 bin/rails 'dashboards:comodos[<id do painel>]'
  desc "Arruma as visões de cômodo de um painel (PUBLICAR=1 publica)"
  task :comodos, [ :dashboard_id ] => :environment do |_t, args|
    ActsAsTenant.without_tenant do
      dashboard = Dashboard.find(args[:dashboard_id])
      ActsAsTenant.with_tenant(dashboard.tenant) do
        Dashboards::RoomLayout.apply!(dashboard, publish: ENV["PUBLICAR"] == "1")
      end
    end
  end
end
