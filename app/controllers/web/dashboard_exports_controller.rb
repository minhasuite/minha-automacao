module Web
  # P2.3: "Exportar como pacote" de um painel: o manifesto de Pacotes com os
  # pontos e áreas do local virando entradas (Dashboards::Export). Técnico ou dono.
  class DashboardExportsController < ApplicationController
    def show
      dashboard = Dashboard.find(params[:id])
      authorize_site!(dashboard.site, :manage)
      manifest = Dashboards::Export.dashboard(dashboard)
      send_data JSON.pretty_generate(manifest), filename: "#{manifest['key']}.json", type: :json
    end
  end
end
