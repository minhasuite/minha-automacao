# Verificação personalizada da Saúde (P3 da proposta de personalização): o
# dono descreve um problema da casa como dado, sem código, e ele entra na
# tela Configurações → Saúde e no aviso diário como as verificações do
# produto (`Health::Checks::Custom`, uma linha por registro).
#
# - `query`: consulta de pontos (`Points::Query`, "quality=unavailable tag=bateria").
#   Sozinha, há problema quando ela acha algum ponto.
# - `expression`: expressão da calculadora das automações (`Automations::Expr`,
#   `count_points("quality=unavailable") > 0`, `sala.temperatura > 30`).
#   Verdadeira = problema. Com a consulta junto, `count` é quantos ela achou.
# - `severity`: "warn" (só na tela) ou "error" (também o aviso diário).
# - `message`: texto em Liquid (`MessageTemplate`) com `count` e `found`
#   (os pontos da consulta, até 20) além do contexto das automações.
class CustomHealthCheck < ApplicationRecord
  include Auditable

  acts_as_tenant :tenant

  SEVERITIES = %w[warn error].freeze
  LIST_MAX = 20

  belongs_to :site

  normalizes :name, :query, :expression, with: ->(v) { v.to_s.squish.presence }

  validates :name, presence: true, length: { maximum: 80 }
  validates :severity, inclusion: { in: SEVERITIES }
  validates :query, :expression, length: { maximum: 500 }
  validates :message, length: { maximum: MessageTemplate::MAX }
  validate { errors.add(:base, :condition_missing) if query.blank? && expression.blank? }
  validate { (e = Points::Query.error(query)) && errors.add(:query, :invalid_query, error: e) if query.present? }
  validate { (e = MessageTemplate.syntax_error(message)) && errors.add(:message, :invalid_template, error: e) }

  audited_attributes :name, :query, :expression, :severity, :enabled

  scope :enabled, -> { where(enabled: true) }

  def severity_label = I18n.t("custom.health.severities.#{severity}")

  # Resultado agora: { problem:, count:, detail: } (levanta Automations::Context::Error
  # se a expressão ou o texto falharem).
  def evaluate
    ctx = Automations::Context.new(site: site)
    found = query.present? ? ctx.query(query) : []
    vars = { "count" => found.size }
    problem = expression.present? ? truthy?(ctx_with(vars).calc(expression)) : found.any?
    { problem: problem, count: found.size, detail: detail(found, vars, problem) }
  end

  # Prévia (formulário e API): [resultado, erro].
  def preview
    [ evaluate, nil ]
  rescue Automations::Context::Error, ArgumentError => e
    [ nil, e.message.truncate(300) ]
  end

  private

  def ctx_with(vars) = Automations::Context.new(site: site, vars: vars)

  def truthy?(v) = ![ nil, false, 0, "", "false", "off" ].include?(v)

  def detail(found, vars, problem)
    if message.present?
      ctx = Automations::Context.new(site: site, vars: vars)
      drops = found.first(LIST_MAX).map { |p| ctx.point_drop(p) }
      return MessageTemplate.render(site, message, vars: vars.merge("found" => drops), limit: 300).presence
    end
    return I18n.t("custom.health.ok") unless problem
    return I18n.t("custom.health.problem") if found.empty?

    names = found.first(5).map(&:name).join(", ")
    I18n.t("custom.health.found", count: found.size, names: names + (found.size > 5 ? " …" : ""))
  end
end
