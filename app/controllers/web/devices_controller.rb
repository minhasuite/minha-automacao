module Web
  # Dispositivos do local: lista no estilo do HA (filtros, busca, ações em
  # massa) e a página do dispositivo com pontos, diagnóstico e onde é usado.
  class DevicesController < ApplicationController
    BULK = { "area" => "Mover para a área", "poll_on" => "Ligar a leitura periódica", "poll_off" => "Desligar a leitura periódica",
             "remove" => "Remover" }.freeze

    def index
      @site = Site.find(params[:site_id])
      authorize_site!(@site, :view)
      scope = @site.devices.includes(:area, :integration, :points).in_situation(params[:situacao].presence).listed
      scope = scope.where(integration_id: params[:integracao]) if params[:integracao].present?
      scope = scope.where(area_id: params[:area].presence == "none" ? nil : params[:area]) if params[:area].present?
      if (q = params[:q].to_s.squish).present?
        like = "%#{Device.sanitize_sql_like(q)}%"
        scope = scope.left_joins(:area).where("devices.name ILIKE :q OR devices.model ILIKE :q OR devices.manufacturer ILIKE :q OR areas.name ILIKE :q", q: like)
      end
      @points = Point.where(device_id: scope.select(:id)).group(:device_id).count
      # Ordem sem acento e sem caixa ("Câmera" junto de "Casa", não depois de "COZ").
      @pagy, @devices = pagy(scope.order(Arel.sql('devices.name COLLATE "und-x-icu"')), limit: 50)
      @integrations = @site.integrations.order(:name)
      @areas = @site.areas.order(:name)
    end

    # Ações em massa: mover de área, ligar/desligar a leitura e remover.
    def bulk
      @site = Site.find(params[:site_id])
      authorize_site!(@site, :manage)
      devices = @site.devices.where(id: Array(params[:ids]))
      back = site_devices_path(@site, **params.permit(:integracao, :area, :situacao, :q).to_h.symbolize_keys)
      return redirect_to(back, alert: "Escolha ao menos um dispositivo.") if devices.none?

      count = devices.count
      case params[:acao]
      when "area" then devices.update_all(area_id: @site.areas.find_by(id: params[:area_id])&.id, updated_at: Time.current)
      when "poll_on" then devices.update_all(poll_s: 1800)
      when "poll_off" then devices.update_all(poll_s: 0)
      when "remove" then devices.find_each(&:destroy!)
      else return redirect_to(back, alert: "Escolha a ação.")
      end
      redirect_to back, notice: "#{BULK[params[:acao]]}: #{count} dispositivo(s)."
    end

    def show
      load_for(:view)
      @points = @device.points.ordered
      @usages = @device.usages
      @problems = Event.where(point_id: @points.map(&:id), kind: "quality").where("payload->>'to' <> 'good'").order(at: :desc).limit(5)
    end

    # "Reconectar": uma leitura pela fila; Tuya tenta as outras versões do protocolo.
    def reconnect
      load_for(:command, risk: "sensitive")
      return redirect_to(@device, alert: "Este dispositivo não tem leitura.") unless Polling.supported?(@device)

      PollDeviceJob.perform_later(@device.id, reconnect: true)
      redirect_to @device, notice: "Reconectando. O resultado aparece no diagnóstico em instantes."
    end

    def new
      @site = Site.find(params[:site_id])
      authorize_site!(@site, :manage)
      @device = @site.devices.new(area_id: params[:area_id].presence)
    end

    def create
      @site = Site.find(params[:site_id])
      authorize_site!(@site, :manage)
      @device = @site.devices.new(device_params)
      return render(:new, status: :unprocessable_content) unless @device.save

      redirect_to @device, notice: "Dispositivo criado. Adicione os pontos dele."
    end

    def edit = load_for(:manage)

    def update
      load_for(:manage)
      return render(:edit, status: :unprocessable_content) unless @device.update(device_params)

      redirect_to @device, notice: "Dispositivo atualizado."
    end

    def destroy
      load_for(:manage)
      @device.destroy!
      redirect_to(@device.area || @site, notice: "Dispositivo excluído.")
    end

    # "Atualizar agora": uma leitura fora da vez, pela fila (só leitura).
    # Operador para cima (quem pode mandar comando sensível).
    def refresh
      load_for(:command, risk: "sensitive")
      return redirect_to(@device, alert: "Este dispositivo não tem leitura.") unless Polling.supported?(@device)

      PollDeviceJob.perform_later(@device.id)
      redirect_to @device, notice: "Leitura pedida. Os valores chegam em instantes."
    end

    private

    def load_for(action, **)
      @device = Device.find(params[:id])
      @site = @device.site
      authorize_site!(@site, action, **)
    end

    def device_params = params.require(:device).permit(:name, :area_id, :driver, :manufacturer, :model, :serial, :disabled, :listen, :poll_min, :host, :protocol_version)
  end
end
