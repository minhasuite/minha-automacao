module Web
  # Cadastro de pontos e comando pela tela (Turbo Frame: só o cartão do ponto
  # é trocado na resposta).
  class PointsController < ApplicationController
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

      redirect_to @device, notice: "Ponto criado."
    end

    def edit = load_for(:manage)

    def update
      load_for(:manage)
      return render(:edit, status: :unprocessable_content) unless @point.update(point_params)

      redirect_to @point.device, notice: "Ponto atualizado."
    end

    def destroy
      load_for(:manage)
      @point.destroy!
      redirect_to @point.device, notice: "Ponto excluído."
    end

    def command
      @point = Point.find(params[:id])
      @site = @point.site
      authorize_site!(@site, :command, risk: @point.risk)
      Points::Command.call(@point, params[:command], params[:value])
      respond(nil)
    rescue Points::Command::Error => e
      respond(e.message)
    end

    private

    def respond(error)
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
                                    :device_class, :scale, :offset, :pulse_ms, :max_on_s, :writable, :hidden, :disabled)
    end
  end
end
