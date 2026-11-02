# Timer por voz (ondaB1, B1; os timers do Assist do HA): "timer de 5
# minutos". Ativo (conta até `ends_at`), pausado (`remaining_s`), terminado
# ou cancelado. O fim é um AssistTimerJob com o carimbo de `ends_at` (job
# velho, depois de pausar ou cancelar, não termina nada) e vira o evento
# "assist_timer_finished" (gatilho Evento das automações) e, se veio de um
# satélite, o aviso nele.
class AssistTimer < ApplicationRecord
  acts_as_tenant :tenant

  belongs_to :site
  belongs_to :user, optional: true

  STATUSES = %w[active paused finished cancelled].freeze
  MAX = 1.day.to_i

  validates :status, inclusion: { in: STATUSES }
  validates :duration_s, numericality: { only_integer: true, in: 1..MAX }
  validates :name, length: { maximum: 60 }

  scope :running, -> { where(status: %w[active paused]) }

  def self.start!(site:, seconds:, name: nil, user: nil, satellite: nil)
    create!(site: site, user: user, satellite_id: satellite&.id, name: name.to_s.squish.first(60).presence, duration_s: seconds).tap(&:schedule!)
  end

  def schedule!(seconds = duration_s)
    update!(status: "active", ends_at: Time.current + seconds, remaining_s: nil)
    AssistTimerJob.set(wait_until: ends_at).perform_later(id, ends_at.iso8601(3))
  end

  def remaining = status == "paused" ? remaining_s.to_i : [ (ends_at - Time.current).round, 0 ].max

  def pause! = status == "active" && update!(status: "paused", remaining_s: remaining, ends_at: nil)
  def resume! = status == "paused" && schedule!(remaining_s.to_i)
  def cancel! = update!(status: "cancelled", ends_at: nil)

  def finish_due!(stamp)
    return unless status == "active" && ends_at&.iso8601(3) == stamp

    update!(status: "finished")
    Automations::Triggers.event(site_id, "assist_timer_finished", { "name" => name, "duration_s" => duration_s, "satellite_id" => satellite_id }.compact)
  end
end
