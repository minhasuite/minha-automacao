# Agenda (ESQUEMA-V1 §4.5, G4: "ligar às 17h / desligar às 23h"): num horário
# fixo ou no nascer/pôr do sol (± minutos, pela latitude/longitude do local),
# nos dias da semana escolhidos, manda um comando num ponto ou aciona uma cena
# (vários pontos = uma cena). Horário no fuso do local. `next_run_at` fica no
# banco e o RunSchedulesJob (a cada minuto) roda o que venceu: reinício não
# perde agenda; atrasada mais que MISSED (servidor fora) é pulada, não dispara
# a luz das 17h às 21h.
class Schedule < ApplicationRecord
  include Auditable

  acts_as_tenant :tenant

  KINDS = LocalizedLabel.for("automations.labels.schedule_kinds", %w[time sunrise sunset])
  MISSED = 5.minutes

  belongs_to :site
  belongs_to :point, optional: true
  belongs_to :scene, optional: true

  before_validation { self.site_id ||= (point || scene)&.site_id }
  before_validation { self.days = Array(days).compact_blank.map(&:to_i).uniq.sort }
  before_validation { self.value = value.presence if value.is_a?(String) }
  before_save :plan, if: -> { enabled && (new_record? || will_save_change_to_enabled? || changed.intersect?(%w[kind time_of_day offset_min days])) }

  validates :name, presence: true
  validates :kind, inclusion: { in: KINDS.keys }
  validates :time_of_day, format: { with: /\A([01]\d|2[0-3]):[0-5]\d\z/, message: :hh_mm }, if: -> { kind == "time" }
  validates :offset_min, numericality: { only_integer: true, in: -720..720 }
  validate :target_fits
  validate :days_fit
  validate :site_has_location, if: -> { kind != "time" }

  normalizes :name, with: ->(v) { v.to_s.squish }

  audited_attributes :name, :enabled, :kind, :time_of_day, :days

  def kind_label = KINDS.fetch(kind, kind)
  def days_label = days.size == 7 ? I18n.t("automations.labels.every_day") : days.map { |d| Automations::Dsl.days[d] }.join(", ")

  def when_label
    base = kind == "time" ? time_of_day : kind_label.downcase
    base += " #{offset_min.positive? ? '+' : '-'} #{offset_min.abs} min" if offset_min.nonzero?
    "#{base}, #{days_label}"
  end

  # Próxima vez depois de `from` (nil = nunca: sem dia marcado ou sem sol).
  def next_after(from)
    zone = ActiveSupport::TimeZone[site.timezone]
    today = from.in_time_zone(zone).to_date
    (0..7).each do |i|
      date = today + i
      next unless days.include?(date.wday)

      at = moment(date, zone)
      return at if at && at > from
    end
    nil
  end

  def run!
    Shadow.for_site(site) { run_now! }
  end

  def run_now!
    scene ? scene.activate!(source: "automation", user: nil) : Points::Command.call(point, command, value, source: "automation", user: nil)
  end

  # Roda as agendas vencidas de todas as empresas (RunSchedulesJob).
  def self.run_due(now = Time.current)
    due = ActsAsTenant.without_tenant { where(enabled: true, next_run_at: ..now).to_a }
    due.each do |s|
      ActsAsTenant.with_tenant(s.tenant) do
        ran = s.next_run_at > now - MISSED
        Automations.safely { s.run! } if ran
        s.update_columns(next_run_at: s.next_after(now), last_run_at: ran ? now : s.last_run_at) # rubocop:disable Rails/SkipsModelValidations
      end
    end
  end

  private

  def plan = self.next_run_at = next_after(Time.current)

  def moment(date, zone)
    at = kind == "time" ? zone.parse("#{date} #{time_of_day}") : Sun.at(kind, date, site.latitude, site.longitude, zone)
    at && (at + offset_min.minutes)
  end

  def target_fits
    return errors.add(:base, :one_target) unless point.nil? ^ scene.nil?
    return errors.add(:base, :other_site) if (point || scene).site_id != site_id
    return if scene

    Points::Command.new(point, command.to_s, value).new_value
  rescue Points::Command::Error => e
    errors.add(:command, e.message)
  end

  def days_fit
    errors.add(:days, :none) if days.empty? || days.any? { |d| !d.between?(0, 6) }
  end

  def site_has_location
    errors.add(:kind, :no_location) unless site&.latitude && site.longitude
  end
end
