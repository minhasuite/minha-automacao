module Web
  # Configurações → Painéis → Aparelhos (ideia 10): "neste aparelho abre o
  # painel X". A web identifica o navegador pelo cookie assinado `ma_device`
  # (criado ao dar nome ao aparelho); o app manda `X-MA-Device` (também pelas
  # telas do servidor). Cada pessoa gerencia os aparelhos que nomeou;
  # dono e administrador gerenciam todos (o tablet da parede é da casa).
  class PanelDevicesController < ApplicationController
    before_action :load_device, only: %i[update destroy]

    def index
      @current_key = PanelDevice.key_for(request, cookies)
      @current = PanelDevice.find_by(key: @current_key) if @current_key
      @devices = manageable.includes(:dashboard, :user).order(:name).to_a
      @dashboards = dashboards
    end

    # Dá nome a ESTE aparelho (e escolhe o painel). Na web, cria o cookie se ainda não houver.
    def create
      key = PanelDevice.key_for(request, cookies) || new_web_key
      device = PanelDevice.find_or_initialize_by(key: key)
      raise ActiveRecord::RecordNotFound unless device.new_record? || can_manage?(device)

      device.assign_attributes(device_params.merge(kind: key.split(":").first, user: device.user || current_user, last_seen_at: Time.current,
                                                   user_agent: request.user_agent.to_s.first(200)))
      device.save!
      redirect_to settings_panel_devices_path, notice: t("panel_devices.saved", name: device.name)
    end

    def update
      @device.update!(device_params)
      redirect_to settings_panel_devices_path, notice: t("panel_devices.saved", name: @device.name)
    end

    def destroy
      @device.destroy!
      redirect_to settings_panel_devices_path, notice: t("panel_devices.removed", name: @device.name)
    end

    private

    def manageable = current_user.admin? ? PanelDevice.all : PanelDevice.where(user: current_user)
    def can_manage?(device) = current_user.admin? || device.user_id == current_user.id

    def load_device
      @device = manageable.find(params[:id])
    end

    # Painéis que a pessoa vê (o aparelho só abre painel que quem está nele vê).
    def dashboards
      sites = Site.visible_to(current_user).order(:name).to_a
      sites.flat_map do |s|
        role = s.role_for(current_user)
        Dashboard.ensure_for(s).select { |d| d.visible_to?(role) }.map { |d| [ "#{s.name} · #{d.name}", d.id ] }
      end
    end

    def device_params
      p = params.require(:panel_device).permit(:name, :dashboard_id, :view)
      p[:dashboard_id] = p[:dashboard_id].presence
      p[:dashboard_id] = nil if p[:dashboard_id] && dashboards.none? { |_, id| id == p[:dashboard_id] }
      p
    end

    def new_web_key
      id = SecureRandom.urlsafe_base64(18)
      cookies.permanent.signed[PanelDevice::COOKIE] = { value: id, httponly: true, same_site: :lax }
      "web:#{id}"
    end
  end
end
