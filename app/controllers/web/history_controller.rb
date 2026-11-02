module Web
  # Histórico (History do HA): vários pontos no mesmo gráfico, com zoom por
  # período (atalhos, deslocar, aproximar/afastar e arrastar no gráfico) e
  # exportação CSV com a mesma janela.
  class HistoryController < ApplicationController
    include SitePick

    def show
      return redirect_to(sites_path, notice: "Crie um local para ver o histórico.") unless pick_site

      @zone = ActiveSupport::TimeZone[@site.timezone] || Time.zone
      @from, @to = Time.use_zone(@zone) { Points::Overlay.window(params) }
      ids = Array(params[:point_ids]).compact_blank.uniq.first(Points::Overlay::MAX)
      found = @site.points.where(id: ids).includes(:device).index_by(&:id)
      @selected = ids.filter_map { |id| found[id] }
      @overlay = Points::Overlay.new(@selected, from: @from, to: @to)
      respond_to do |format|
        format.html
        format.csv do
          send_data @overlay.to_csv(@zone), type: "text/csv; charset=utf-8",
                                            filename: "historico-#{@from.in_time_zone(@zone).strftime('%Y%m%d-%H%M')}.csv"
        end
      end
    end
  end
end
