module Web
  # Helpers do local (F8e), como no HA: lista com busca, filtro por tipo e o
  # valor (muda ali mesmo pelo PointsController#command), catálogo de tipos e
  # cadastro. Tudo por tipo vem do plugin (`HelperTypes`) e da partial
  # `forms/_<key>`. Ver: qualquer papel; cadastro: técnico ou dono.
  class SiteHelpersController < ApplicationController
    def index
      @site = Site.find(params[:site_id])
      authorize_site!(@site, :view)
      scope = @site.points.helpers.includes(:area, :device)
      scope = scope.where(helper: params[:tipo]) if params[:tipo].present?
      if (q = params[:q].to_s.squish).present?
        scope = scope.where("points.name ILIKE :q OR points.key ILIKE :q", q: "%#{Point.sanitize_sql_like(q)}%")
      end
      scope = scope.labeled(params[:rotulo]) if params[:rotulo].present?
      @labels = Point.labels_in(@site.points.helpers)
      @pagy, @helpers = pagy(scope.includes(:tags).reorder(Arel.sql("points.category IS NULL, lower(points.category)")).ordered, limit: 50)
      @counts = @site.points.helpers.group(:helper).count
    end

    # Sem tipo: o catálogo. Com tipo: o formulário dele.
    def new
      @site = Site.find(params[:site_id])
      authorize_site!(@site, :manage)
      @plugin = HelperTypes.plugin(params[:tipo]) or return render(:catalog)

      @point = HelperTypes.build(@site, @plugin)
    end

    def create
      @site = Site.find(params[:site_id])
      authorize_site!(@site, :manage)
      @plugin = HelperTypes.plugin(params[:tipo]) or return redirect_to(new_site_helper_path(@site))

      @point = HelperTypes.build(@site, @plugin)
      return render(:new, status: :unprocessable_content) unless HelperTypes.save(@point, form)

      redirect_to site_helpers_path(@site), notice: t("site_helpers.flash.created", name: @point.name)
    end

    def edit
      load_for(:manage)
      @usages = Point.usages(@site, Point.where(id: @point.id))
    end

    def update
      load_for(:manage)
      unless HelperTypes.save(@point, form)
        @usages = Point.usages(@site, Point.where(id: @point.id))
        return render(:edit, status: :unprocessable_content)
      end

      redirect_to site_helpers_path(@site), notice: t("site_helpers.flash.saved", name: @point.name)
    end

    def destroy
      load_for(:manage)
      @point.destroy!
      redirect_to site_helpers_path(@site), notice: t("site_helpers.flash.deleted", name: @point.name)
    end

    private

    def load_for(action)
      @point = Point.helpers.find(params[:id])
      @site = @point.site
      @plugin = @point.helper_type
      authorize_site!(@site, action)
    end

    # Campos comuns + os que a partial do tipo manda (o plugin lê o que conhece).
    def form = params.fetch(:helper, {}).permit(:name, :icon, :area_id, :restore, :label_list, :category, *@plugin.fields).to_h
  end
end
