module Web
  # Configurações → Plano (produto): o plano da instalação, o uso de cada
  # limite e a comparação. Trocar de plano depende de um provedor de
  # pagamento (Licensing::PAYMENT_PROVIDERS, ainda vazio).
  class LicensesController < ApplicationController
    before_action -> { raise ActiveRecord::RecordNotFound unless current_user.admin? }

    def show
      @tenant = current_user.tenant
      @plan = Licensing.plan(@tenant)
    end
  end
end
