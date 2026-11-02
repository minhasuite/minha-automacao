module Web
  # Tela "Expor" do local (ondaA1, A3): uma linha por ponto, uma coluna por
  # assistente (Exposure.targets), com filtro e marcação em massa. Ver:
  # qualquer papel; mudar: dono do local (como a Alexa e as pontes).
  class ExposuresController < ApplicationController
    before_action -> { @site = Site.find(params[:site_id]) }

    def show
      authorize_site!(@site, :view)
      @targets = Exposure.targets(@site)
      scope = @site.points.includes(:device, :area, :tags).where(disabled: false, hidden: false).ordered
      if (q = params[:q].to_s.squish).present?
        like = "%#{Point.sanitize_sql_like(q)}%"
        scope = scope.where("points.name ILIKE :q OR array_to_string(points.aliases, ' ') ILIKE :q", q: like)
      end
      scope = scope.labeled(params[:rotulo]) if params[:rotulo].present?
      @points = scope.to_a
      if params[:area].present?
        ids = Area.subtree_ids(@site.areas.pluck(:id, :parent_id), params[:area])
        @points.select! { |p| ids.include?(p.effective_area_id) }
      end
      @points.select! { |p| @targets.any? { |t| t.applies?(p) && t.exposed?(p) } } if params[:so] == "expostos"
      @labels = Point.labels_in(@site.points)
    end

    def update
      authorize_site!(@site, :admin)
      targets = Exposure.targets(@site).index_by(&:key)
      points = @site.points.where(id: params.fetch(:x, {}).keys).index_by(&:id)
      confirm = params[:confirm] == "1"
      changed = 0
      errors = params.fetch(:x, {}).to_unsafe_h.flat_map do |id, cols|
        point = points[id] or next []
        cols.to_h.filter_map do |key, v|
          t = targets[key]
          next unless t&.applies?(point)

          on = v == "1"
          next if t.exposed?(point) == on

          changed += 1
          t.set!(point, on, confirm: confirm)
        end
      end
      back = params[:back].to_s.start_with?("/") ? params[:back] : site_exposure_path(@site)
      redirect_to back, **(errors.any? ? { alert: errors.first(3).to_sentence } : { notice: changed.zero? ? "Nada mudou." : "Exposição salva (#{changed} mudança#{'s' if changed != 1})." })
    end
  end
end
