# Uma assinatura da EMPRESA (copiado do minhas-compras, com tenant no lugar do
# usuário). `user` é quem comprou — só a conta Google dele gerencia/cancela.
# Mais de uma ao mesmo tempo é possível (dois membros assinaram): quem decide
# o plano é Billing::Entitlement, olhando todas.
class Subscription < ApplicationRecord
  # `licencas` = comprada pela web na central (Licencas::Sync).
  SOURCES = %w[play manual licencas].freeze

  # Estados que ainda dão acesso. `grace`/`on_hold` = a Play ainda tenta
  # cobrar (cortar quem só trocou de cartão perde assinante); `canceled` na
  # Play é "não renova mais", vale até o fim do período pago; `trial` é o
  # teste grátis de 14 dias.
  ENTITLING = %w[active trial grace on_hold canceled].freeze
  STATUSES = (ENTITLING + %w[paused expired pending replaced]).freeze

  belongs_to :tenant
  belongs_to :user, optional: true

  validates :source, inclusion: { in: SOURCES }
  validates :external_id, presence: true, uniqueness: { scope: :source }
  validates :status, inclusion: { in: STATUSES }
  validates :plan, inclusion: { in: Plans::ALL }

  scope :entitling, -> { where(status: ENTITLING) }

  def entitling?
    return false unless ENTITLING.include?(status)
    # Sem validade: vale enquanto o status disser — exceto cancelada.
    return status != "canceled" if expires_at.nil?

    expires_at.future?
  end
end
