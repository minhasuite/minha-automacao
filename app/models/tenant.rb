# A empresa. Tudo que é dela pertence ao tenant; os membros são
# os usuários com o mesmo tenant_id.
#
# `plan` (free/pro/max, Plans) é da EMPRESA: vem da assinatura da Play de
# qualquer membro (Billing::Entitlement, `plan_provider: "play"`) ou é dado à
# mão (`manual`, cortesia). Governa a IA (AiPlanFeature).
class Tenant < ApplicationRecord
  include Auditable

  PLANS = Plans::ALL
  TIMEZONE = "America/Sao_Paulo".freeze

  has_many :users, dependent: :destroy
  has_many :subscriptions, dependent: :delete_all

  validates :name, presence: true
  validates :plan, inclusion: { in: PLANS }
  validates :uf, format: { with: /\A[A-Z]{2}\z/ }, allow_blank: true

  normalizes :uf, with: ->(v) { v.to_s.strip.upcase.presence }
  normalizes :document, :phone, with: ->(v) { v.to_s.gsub(/\D/, "").presence }

  audited_attributes :plan

  def effective_plan = Plans.normalize(plan).to_sym
  def timezone = TIMEZONE
end
