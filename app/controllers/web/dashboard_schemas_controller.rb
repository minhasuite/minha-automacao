module Web
  # P1.5: o JSON Schema do painel (Dashboards::JsonSchema), gerado do registro
  # de widgets, para autocompletar e documentar. Qualquer pessoa com conta.
  class DashboardSchemasController < ApplicationController
    def show
      expires_in 10.minutes, public: false
      render json: Dashboards::JsonSchema.call
    end
  end
end
