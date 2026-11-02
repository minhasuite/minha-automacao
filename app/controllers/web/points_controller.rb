module Web
  # Cadastro de pontos, comando pela tela (Turbo Frame: só o cartão do ponto
  # é trocado na resposta) e a página do ponto com gráfico e últimos eventos.
  class PointsController < ApplicationController
    def show
      load_for(:view)
      @range = params[:range].presence_in(Points::History::RANGES.keys) || "24h"
      @history = Points::History.new(@point, from: (Time.current - Points::History::RANGES.fetch(@range)).iso8601)
      @timeline = Points::Timeline.call(@point)
    end

    def new
      @device = Device.find(params[:device_id])
      @site = @device.site
      authorize_site!(@site, :manage)
      @point = @device.points.new(capability: "onoff")
    end

    def create
      @device = Device.find(params[:device_id])
      @site = @device.site
      authorize_site!(@site, :manage)
      @point = @device.points.new(point_params.merge(site: @site))
      return render(:new, status: :unprocessable_content) unless @point.save

      redirect_to @device, notice: t("notices.point_created")
    end

    def edit = load_for(:manage)

    def update
      load_for(:manage)
      return render(:edit, status: :unprocessable_content) unless @point.update(point_params)

      redirect_to @point.device, notice: t("notices.point_updated")
    end

    def destroy
      load_for(:manage)
      @point.destroy!
      redirect_to @point.device, notice: t("notices.point_deleted")
    end

    def command
      @point = Point.find(params[:id])
      @site = @point.site
      authorize_site!(@site, :command, risk: @point.risk)
      command = Points::Command.call(@point, params[:command], params[:value], source: "web")
      @point.reload
      respond(command.error)
    rescue Points::Command::Error => e
      respond(e.message)
    end

    private

    # Leitor (viewer) vê o painel e o que ele abre; comando e cadastro barram pelo papel.
    def viewer_allowed? = true

    def respond(error)
      # Widget de dashboard: volta para o próprio quadro (recarrega só ele).
      if params[:dashboard_id].present? && params[:widget_id].present? && turbo_frame_request?
        flash[:alert] = error if error
        return redirect_to(widget_dashboard_path(params[:dashboard_id], widget_id: params[:widget_id]), status: :see_other)
      end
      return render(partial: "web/points/point", locals: { point: @point, error: error }) if turbo_frame_request?

      redirect_back fallback_location: @point.device, **(error ? { alert: error } : {})
    end

    def load_for(action)
      @point = Point.find(params[:id])
      @device = @point.device
      @site = @point.site
      authorize_site!(@site, action)
    end

    def point_params
      params.require(:point).permit(:name, :key, :capability, :unit, :area_id, :min, :max, :step, :options_text, :risk, :confirm,
                                    :device_class, :scale, :offset, :pulse_ms, :max_on_s, :writable, :hidden, :disabled, :label_list, :alias_list)
    end
  end
end
