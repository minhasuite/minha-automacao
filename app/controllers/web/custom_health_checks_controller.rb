module Web
  # Verificações personalizadas da Saúde (P3): Configurações → Saúde →
  # Verificações personalizadas. Só administradores, como a Saúde.
  # "Ver prévia" roda a verificação com o que está no formulário, sem salvar.
  class CustomHealthChecksController < ApplicationController
    before_action -> { raise ActiveRecord::RecordNotFound unless current_user.admin? }
    before_action -> { @check = CustomHealthCheck.find(params[:id]) }, only: %i[edit update destroy]

    def index
      @checks = CustomHealthCheck.includes(:site).order(:name).to_a
      @results = @checks.to_h { |c| [ c.id, Health::Checks::Custom.item_for(c) ] }
    end

    def new
      @check = CustomHealthCheck.new(site: Site.order(:name).first, severity: "warn", query: "quality=unavailable")
      render :edit
    end

    def create
      @check = CustomHealthCheck.new(check_params)
      save(t("custom.health.flash.created"))
    end

    def edit; end

    def update
      @check.assign_attributes(check_params)
      save(t("custom.health.flash.saved"))
    end

    def destroy
      @check.destroy!
      redirect_to settings_health_checks_path, notice: t("custom.health.flash.removed")
    end

    private

    def save(notice)
      if params[:preview].present?
        @check.valid?
        @check.errors.delete(:name) # prévia antes de dar nome
        @preview = @check.preview if @check.errors.empty?
        return render(:edit, status: :unprocessable_content)
      end
      return render(:edit, status: :unprocessable_content) unless @check.save

      redirect_to settings_health_checks_path, notice: notice
    end

    def check_params
      p = params.require(:custom_health_check).permit(:site_id, :name, :query, :expression, :severity, :message, :enabled)
      p[:site_id] = Site.find(p[:site_id]).id if p[:site_id].present? # 404 fora da instalação
      p
    end
  end
end
