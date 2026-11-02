module Web
  # Conjuntos de dados do local (Lote 2): lista, cadastro (nome, campos e
  # retenção) e os registros com filtros (os mesmos da ação "Consultar
  # dados") e exportação CSV. Ver: qualquer papel; cadastro: técnico ou dono.
  class DatasetsController < ApplicationController
    def index
      @site = Site.find(params[:site_id])
      authorize_site!(@site, :view)
      @datasets = @site.datasets.order(:name).to_a
      @counts = DatasetRecord.where(dataset_id: @datasets.map(&:id)).group(:dataset_id).count
    end

    def show
      load_for(:view)
      @filters = params[:filtros].to_s
      @days = params[:dias].to_i.clamp(0, 3650)
      scope = Datasets::Query.new(@dataset, op: "rows", window_s: (@days.days.to_i if @days.positive?), filters: @filters).scope.order(created_at: :desc)
      @columns = (@dataset.field_names + scope.limit(200).pluck(:data).flat_map(&:keys)).uniq.first(Dataset::MAX_FIELDS)
      respond_to do |format|
        format.html { @pagy, @records = pagy(scope, limit: 50) }
        format.csv { send_data csv(scope.limit(50_000)), filename: "#{@dataset.key}-#{Date.current}.csv", type: "text/csv" }
      end
    rescue ArgumentError => e
      @error = e.message
      @pagy, @records = pagy(@dataset.records.none, limit: 50)
      render :show, status: :unprocessable_content
    end

    def new
      @site = Site.find(params[:site_id])
      authorize_site!(@site, :manage)
      @dataset = @site.datasets.new(retention_days: 365)
    end

    def create
      @site = Site.find(params[:site_id])
      authorize_site!(@site, :manage)
      @dataset = @site.datasets.new(form)
      return render(:new, status: :unprocessable_content) unless @dataset.save

      redirect_to dataset_path(@dataset), notice: t("datasets.flash.created", name: @dataset.name)
    end

    def edit = load_for(:manage)

    def update
      load_for(:manage)
      return render(:edit, status: :unprocessable_content) unless @dataset.update(form)

      redirect_to dataset_path(@dataset), notice: t("datasets.flash.saved", name: @dataset.name)
    end

    def destroy
      load_for(:manage)
      @dataset.destroy!
      redirect_to site_datasets_path(@site), notice: t("datasets.flash.deleted", name: @dataset.name)
    end

    private

    def load_for(action)
      @dataset = Dataset.find(params[:id])
      @site = @dataset.site
      authorize_site!(@site, action)
    end

    def form = params.require(:dataset).permit(:name, :fields_text, :retention_days).tap { |p| p[:retention_days] = p[:retention_days].presence }

    # CSV à mão (sem a gem): aspas dobradas e prefixo contra fórmula no Excel.
    def csv(scope)
      cell = lambda do |v|
        s = v.is_a?(Hash) || v.is_a?(Array) ? v.to_json : v.to_s
        s = "'#{s}" if s.start_with?("=", "+", "-", "@") && !s.match?(/\A-?\d/)
        s.match?(/[",\n\r;]/) ? "\"#{s.gsub('"', '""')}\"" : s
      end
      zone = @site.timezone
      lines = [ ([ "em" ] + @columns).map(&cell).join(",") ]
      scope.each { |r| lines << ([ r.created_at.in_time_zone(zone).iso8601 ] + @columns.map { |c| r.data[c] }).map(&cell).join(",") }
      "#{lines.join("\n")}\n"
    end
  end
end
