module Web
  # Saúde do sistema (Configurações → Saúde): cada verificação do registro
  # `Health::CHECKS` com seus itens. Só administradores (membro nem vê que existe).
  class HealthController < ApplicationController
    def show
      raise ActiveRecord::RecordNotFound unless current_user.admin?

      @results = Health.run(current_user.tenant)
      @status = Health.worst(@results.map(&:status))
    end
  end
end
