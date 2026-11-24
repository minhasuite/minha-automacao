module Web
  # Central do integrador (Integrator, só com INTEGRATOR_HUB=1, só o dono): as instalações dos clientes com o
  # semáforo, a página de cada uma (último resumo, gráficos, freio de versão) e o token, que aparece só na resposta
  # da criação (nada de flash/cookie), como as chaves de integração.
  class IntegratorController < ApplicationController
    ORDER = %w[offline error warn waiting ok].freeze

    before_action :require_owner!
    before_action { raise ActionController::RoutingError, "Not Found" unless Integrator.hub? }
    before_action :set_installation, only: %i[show update destroy]

    def index
      @installations = Installation.order(:name).to_a.sort_by { |i| [ ORDER.index(i.status) || 9, i.name ] }
    end

    def show
      @samples = @installation.samples.where(at: 2.days.ago..).order(:at).to_a
    end

    def create
      @created, @plain = Installation.create_with_token!(name: params.require(:installation)[:name])
      index
      render :index
    rescue ActiveRecord::RecordInvalid => e
      redirect_to integrator_path, alert: e.record.errors.full_messages.to_sentence
    end

    # Nome, observações e o freio de versão.
    def update
      @installation.update!(params.require(:installation).permit(:name, :notes, :max_version))
      redirect_to integrator_installation_path(@installation), notice: t("integrator.flash.saved")
    rescue ActiveRecord::RecordInvalid => e
      redirect_to integrator_installation_path(@installation), alert: e.record.errors.full_messages.to_sentence
    end

    def destroy
      @installation.destroy!
      redirect_to integrator_path, notice: t("integrator.flash.removed", name: @installation.name)
    end

    private

    def set_installation = @installation = Installation.find(params[:id])
  end
end
