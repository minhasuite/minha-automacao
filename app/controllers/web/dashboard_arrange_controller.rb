module Web
  # Arrumação no editor do painel (P2.1 e ideias 3 e 6 da proposta de
  # personalização), só técnico ou dono, sempre no RASCUNHO:
  #
  # - "Arrumar esta visão": prévia antes → depois (`Dashboards::RoomLayout`
  #   com as regras do painel/local) e "Aplicar ao rascunho";
  # - visão automática por área (`Dashboards::AutoViews`) e "Congelar";
  # - montagem por frase com a IA da instalação (`Dashboards::Compose`);
  # - "Mudanças": o publicado → o rascunho, com o Publicar.
  class DashboardArrangeController < ApplicationController
    before_action :load_dashboard

    def preview
      @view = find_view(@dashboard.working_draft) or return redirect_to(edit_dashboard_path(@dashboard), alert: t("dashboards.flash.gone"))
      return redirect_to(edit_dashboard_path(@dashboard, view: @view["id"]), alert: t("arrange.flash.auto_view")) if Dashboards::AutoViews.auto?(@view)

      after = arranged(@dashboard.working_draft, @view["id"])
      @diff = Dashboards::ArrangeDiff.call(@dashboard.working_draft, after, names: names, only: [ @view["id"] ])
      @same = @diff.all? { _1.status == :same }
    end

    def apply
      view = find_view(@dashboard.working_draft) or return redirect_to(edit_dashboard_path(@dashboard), alert: t("dashboards.flash.gone"))
      save!(arranged(@dashboard.working_draft, view["id"]), view["id"], t("arrange.flash.arranged"))
    end

    def auto_view
      defn = @dashboard.working_draft.deep_dup
      if (view = find_view(defn)) && view["area"].present?
        view["auto"] = { "area" => view["area"] }
        return save!(Dashboards::AutoViews.expand(defn, @site), view["id"], t("arrange.flash.auto_on"))
      end

      area = @site.areas.find(params[:area_id])
      view = Dashboards::AutoViews.new_area_view(defn, area)
      defn["views"] << view
      save!(Dashboards::AutoViews.expand(defn, @site), view["id"], t("arrange.flash.auto_added"))
    end

    def freeze_view
      view = find_view(@dashboard.working_draft) or return redirect_to(edit_dashboard_path(@dashboard), alert: t("dashboards.flash.gone"))
      save!(Dashboards::AutoViews.freeze_view(@dashboard.working_draft, @site, view["id"]), view["id"], t("arrange.flash.frozen"))
    end

    def compose
      result = Dashboards::Compose.call(@dashboard, params[:text], user: current_user)
      @dashboard.update!(draft: result.definition)
      notice = t("arrange.flash.composed")
      notice = "#{notice} #{t('arrange.flash.dropped', names: result.dropped.first(5).to_sentence)}" if result.dropped.any?
      redirect_to changes_dashboard_path(@dashboard, view: result.view_id), notice: notice
    rescue Dashboards::Compose::Error => e
      redirect_to edit_dashboard_path(@dashboard, view: params[:view_id]), alert: e.message
    end

    def changes
      @diff = Dashboards::ArrangeDiff.call(@dashboard.published, @dashboard.working_draft, names: names)
      @focus = params[:view]
      @same = @diff.all? { _1.status == :same }
    end

    private

    def load_dashboard
      @dashboard = Dashboard.find(params[:id])
      @site = @dashboard.site
      authorize_site!(@site, :manage)
      raise ActiveRecord::RecordNotFound unless @dashboard.visible_to?(@site_role)
    end

    def find_view(defn) = Array(defn["views"]).find { |v| v["id"] == params[:view].to_s }
    def names = @site.points.pluck(:id, :name).to_h

    def arranged(defn, view_id)
      layout = Dashboards::RoomLayout.new(@site, rules: Dashboards::Arrange.rules(@site, defn))
      defn.merge("views" => defn["views"].map { |v| v["id"] == view_id ? layout.view(v).first : v })
    end

    def save!(defn, view_id, notice)
      errors = Dashboards::Schema.errors(defn)
      return redirect_to(edit_dashboard_path(@dashboard, view: view_id), alert: errors.first(3).to_sentence) if errors.any?

      @dashboard.update!(draft: defn)
      redirect_to edit_dashboard_path(@dashboard, view: view_id), notice: notice
    end
  end
end
