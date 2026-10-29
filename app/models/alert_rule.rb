# Regra de alerta (ESQUEMA-V1 §4.5, G4: "porta de vidro aberta há 5 min,
# 10, 20…"). Condição sobre um ponto (`operator` + `value`) por `for_s`
# segundos abre um Alert, que avisa pelas etapas de `escalation`
# ([{wait_s, channels}], cada espera contada da etapa anterior) e depois repete
# a última a cada `repeat_s` até alguém marcar "ciente" ou a condição sumir
# (`auto_resolve`). A espera e as etapas são jobs agendados no banco.
class AlertRule < ApplicationRecord
  include Auditable

  acts_as_tenant :tenant

  OPERATORS = { "eq" => "igual a", "ne" => "diferente de", "gt" => "maior que", "lt" => "menor que" }.freeze
  SEVERITIES = { "info" => "Informação", "warning" => "Atenção", "critical" => "Crítico" }.freeze

  belongs_to :site
  belongs_to :point
  has_many :alerts, dependent: nil # cascade no banco

  before_validation { self.site_id ||= point&.site_id }
  before_validation { self.value = point.cast(value) if point && value.is_a?(String) }
  before_validation :tidy_escalation
  after_commit :reevaluate, on: %i[create update]

  validates :name, presence: true
  validates :operator, inclusion: { in: OPERATORS.keys }
  validates :severity, inclusion: { in: SEVERITIES.keys }
  validates :for_s, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :repeat_s, numericality: { only_integer: true, greater_than_or_equal_to: 60 }, allow_nil: true
  validate :escalation_fits
  validate { errors.add(:point, "precisa ser deste local") if point && point.site_id != site_id }
  validate { errors.add(:value, "precisa ser número para maior/menor") if operator.in?(%w[gt lt]) && !value.is_a?(Numeric) }

  normalizes :name, with: ->(v) { v.to_s.squish }

  audited_attributes :name, :enabled, :operator, :value, :for_s, :escalation, :repeat_s

  def severity_label = SEVERITIES.fetch(severity, severity)
  def operator_label = OPERATORS.fetch(operator, operator)

  def self.evaluate(point)
    where(point_id: point.id, enabled: true).find_each(&:evaluate)
  end

  def match?(v)
    case operator
    when "eq" then v == value
    when "ne" then v != value
    when "gt" then v.is_a?(Numeric) && v > value
    when "lt" then v.is_a?(Numeric) && v < value
    end
  end

  # Abre (agora ou depois de `for_s` no estado), resolve, ou nada.
  def evaluate
    open = alerts.active.first
    return open&.resolve! if !match?(point.value) && auto_resolve
    return if open || !match?(point.value)

    since = point.changed_at || Time.current
    due = since + for_s
    return AlertCheckJob.set(wait_until: due).perform_later(id, since.iso8601(6)) if due > Time.current

    alert = alerts.create!(site: site, point: point, opened_at: Time.current)
    alert.schedule_step
  rescue ActiveRecord::RecordNotUnique
    nil # outro processo abriu ao mesmo tempo
  end

  # Formulário: etapas {"0" => {wait_min, channels: []}} (minutos na tela).
  def steps=(rows)
    rows = rows.values if rows.respond_to?(:values)
    self.escalation = Array(rows).filter_map do |r|
      r = r.to_h.stringify_keys
      next if r["wait_min"].blank?

      { "wait_s" => (r["wait_min"].to_f * 60).round, "channels" => Array(r["channels"]).compact_blank }
    end
  end

  def for_min = (for_s % 60).zero? ? for_s / 60 : for_s / 60.0
  def for_min=(v)
    self.for_s = (v.to_s.tr(",", ".").to_f * 60).round
  end

  def repeat_min = repeat_s && (repeat_s / 60)
  def repeat_min=(v)
    self.repeat_s = v.present? ? (v.to_f * 60).round : nil
  end

  private

  def tidy_escalation
    self.escalation = [ { "wait_s" => 0, "channels" => Notifier::CHANNELS.keys } ] if escalation.blank?
    self.escalation = escalation.map { |s| s.to_h.stringify_keys.slice("wait_s", "channels") }
  end

  def escalation_fits
    ok = escalation.all? do |s|
      s["wait_s"].is_a?(Integer) && s["wait_s"] >= 0 && Notifier.valid_channels?(s["channels"])
    end
    errors.add(:escalation, "precisa de etapas com espera (≥ 0) e canais válidos") unless ok
  end

  def reevaluate
    return alerts.active.find_each(&:resolve!) unless enabled

    evaluate
  end
end
