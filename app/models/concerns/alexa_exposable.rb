# "Expor para a Alexa" (F9) em ponto e cena: desligado por padrão, nome
# falado opcional e, se o risco for crítico (portão, sirene, fechadura,
# alarme), só liga com a confirmação explícita (`alexa_risk_confirmed`).
module AlexaExposable
  extend ActiveSupport::Concern

  included do
    attr_accessor :alexa_risk_confirmed

    normalizes :alexa_name, with: ->(v) { v.to_s.squish.presence }
    validates :alexa_name, length: { maximum: 60 }
    validate :alexa_critical_confirmed
  end

  def alexa_label = alexa_name.presence || name

  private

  def alexa_critical_confirmed
    return unless alexa_exposed && risk == "critical" && (new_record? || will_save_change_to_alexa_exposed?)
    return if ActiveModel::Type::Boolean.new.cast(alexa_risk_confirmed)

    errors.add(:alexa_exposed, "de #{name} (risco crítico) precisa da confirmação")
  end
end
