module Web
  # Base das telas das primitivas de automação (F4): criar, editar,
  # ativar/desativar (PATCH com `enabled`) e excluir. Cadastro: técnico ou
  # dono. A subclasse diz o modelo, o rótulo e os campos; o formulário fica em
  # `web/<controller>/_form`. `back` (caminho local) volta para a página do
  # ponto quando a regra nasceu lá.
  class AutomationController < ApplicationController
    class_attribute :model, :label

    helper_method :back_path, :label_text

    def new
      load_site
      @record = model.new(defaults)
      render "web/automation/edit"
    end

    def create
      load_site
      @record = model.new(record_params.merge(site: @site))
      return render("web/automation/edit", status: :unprocessable_content) unless @record.save

      redirect_to back_path, notice: t("automations.flash.saved", what: label_text)
    end

    def edit
      load_record
      render "web/automation/edit"
    end

    def update
      load_record
      return render("web/automation/edit", status: :unprocessable_content) unless @record.update(record_params)

      redirect_to back_path, notice: t("automations.flash.saved", what: label_text)
    end

    def destroy
      load_record
      @record.destroy!
      redirect_to back_path, notice: t("automations.flash.deleted", what: label_text)
    end

    private

    # Rótulo da primitiva no idioma da tela (automations.primitives.<controller>).
    def label_text = t("automations.primitives.#{controller_name}", default: label)

    def load_site
      @site = Site.find(params[:site_id])
      authorize_site!(@site, :manage)
    end

    def load_record(action = :manage)
      @record = model.find(params[:id])
      @site = @record.site
      authorize_site!(@site, action)
    end

    def back_path = url_from(params[:back].presence) || rules_site_path(@site)
    def defaults = {}
    def record_params = params.require(model.model_name.param_key).permit(*permitted)
  end
end
