module Web
  # Configurações → Hardware (ondaA2 A13; o "Hardware" e a "Rede" do HA):
  # a máquina, a rede do host, portas seriais e USB lidas pelo supervisor, e
  # reiniciar/desligar a máquina. Só o dono.
  class HardwareController < ApplicationController
    before_action :require_owner!

    def show
      @available = Host.available?
      @host = Host.info(refresh: params[:atualizar].present?)
      @wifi = (Host.wifi_networks rescue []) if @available && params[:wifi].present? # rubocop:disable Style/RescueModifier
    end

    # resto (7.3): IP fixo ou DHCP numa interface, e Wi-Fi (o "Rede" do HAOS).
    def network
      Host.network!(params, user: current_user)
      redirect_to settings_hardware_path, notice: t("resto.host.network_saved")
    rescue Apps::Supervisor::Error => e
      redirect_to settings_hardware_path, alert: e.message
    end

    def wifi
      Host.wifi!(params, user: current_user)
      redirect_to settings_hardware_path, notice: t("resto.host.wifi_saved", ssid: params[:ssid])
    rescue Apps::Supervisor::Error => e
      redirect_to settings_hardware_path, alert: e.message
    end

    def power
      action = params[:acao].to_s
      raise ActiveRecord::RecordNotFound unless Host::ACTIONS.key?(action)

      Host.power!(action, user: current_user)
      redirect_to settings_hardware_path, notice: t("hardware.power.started.#{action}")
    rescue Apps::Supervisor::Error => e
      redirect_to settings_hardware_path, alert: e.message
    end
  end
end
