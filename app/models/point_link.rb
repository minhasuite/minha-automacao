# Espelhamento entre pontos (ESQUEMA-V1 §4.2, G4): o interruptor do terraço
# acende a escada; o interruptor do portão aciona o relé do portão.
#   mirror  → o destino fica igual à origem (liga/desliga)
#   invert  → o destino fica o contrário
#   trigger → a origem chegou em `trigger_value` (padrão: ligado) → aciona o
#             destino (liga, pulsa o portão ou aperta o botão); o `pulse_ms`
#             do destino desliga sozinho
# `bidirectional` (só mirror/invert) vale nos dois sentidos. Contra laço e eco:
# não comanda destino que já está no valor, não forma ciclo com outros
# espelhamentos e ignora a volta do próprio comando (ECHO_WINDOW).
class PointLink < ApplicationRecord
  include Auditable

  acts_as_tenant :tenant

  MODES = { "mirror" => "Espelhar", "invert" => "Inverter", "trigger" => "Acionar" }.freeze
  # Comando do modo trigger por capacidade do destino.
  FIRE = { "onoff" => "on", "gate" => "pulse", "command" => "press" }.freeze
  ECHO_WINDOW = 15.seconds

  belongs_to :site
  belongs_to :source_point, class_name: "Point"
  belongs_to :target_point, class_name: "Point"

  before_validation { self.site_id ||= source_point&.site_id }
  before_validation { self.trigger_value = source_point.cast(trigger_value) if source_point && trigger_value.is_a?(String) }

  validates :mode, inclusion: { in: MODES.keys }
  validates :target_point_id, uniqueness: { scope: :source_point_id, message: "já está ligado a esta origem" }
  validate :points_fit
  validate :no_cycle

  audited_attributes :mode, :bidirectional, :enabled

  scope :enabled, -> { where(enabled: true) }

  def mode_label = MODES.fetch(mode, mode)

  # Valor novo em `point`: aplica nos destinos (e na origem dos bidirecionais).
  def self.propagate(point)
    enabled.where(source_point_id: point.id).includes(:target_point).find_each { |l| l.forward(point, l.target_point) }
    enabled.where(target_point_id: point.id, bidirectional: true).includes(:source_point).find_each { |l| l.forward(point, l.source_point) }
  end

  def forward(from, to)
    return if echo?(from, to)

    command = command_for(from.value) or return
    return if command.in?(%w[on off]) && to.value == (command == "on") # já está assim

    Points::Command.call(to, command, nil, source: "automation", user: nil, origin: from)
  end

  private

  def command_for(value)
    case mode
    when "mirror" then value ? "on" : "off"
    when "invert" then value ? "off" : "on"
    when "trigger" then FIRE[target_point.capability] if value == (trigger_value.nil? ? true : trigger_value)
    end
  end

  # `from` mudou porque um espelhamento vindo de `to` mandou, e chegou no
  # valor pedido: é o eco do nosso comando, não volta.
  def echo?(from, to)
    last = from.commands.where(source: "automation", origin_point_id: to.id, created_at: ECHO_WINDOW.ago..).order(created_at: :desc).first
    last && last.command == (from.value ? "on" : "off")
  end

  def points_fit
    return unless source_point && target_point

    errors.add(:target_point, "precisa ser outro ponto") if source_point_id == target_point_id
    errors.add(:target_point, "precisa ser deste local") if target_point.site_id != site_id || source_point.site_id != site_id
    if mode == "trigger"
      errors.add(:target_point, "precisa ser liga/desliga, portão ou botão") unless FIRE.key?(target_point.capability) && target_point.writable
      errors.add(:bidirectional, "só vale para espelhar ou inverter") if bidirectional
    else
      errors.add(:source_point, "precisa ser liga/desliga ou sensor") unless source_point.bool?
      errors.add(:target_point, "precisa ser liga/desliga e receber comando") unless target_point.capability == "onoff" && target_point.writable
      errors.add(:bidirectional, "exige origem liga/desliga") if bidirectional && !(source_point.capability == "onoff" && source_point.writable)
    end
  end

  # Ciclo com outros espelhamentos (A→B→C→A) não se estabiliza com aparelho
  # de verdade (o comando chega depois); o par bidirecional é o único ciclo aceito.
  def no_cycle
    return unless enabled && source_point_id && target_point_id && site_id

    edges = Hash.new { |h, k| h[k] = [] }
    PointLink.enabled.where(site_id: site_id).where.not(id: id).find_each do |l|
      edges[l.source_point_id] << l.target_point_id
      edges[l.target_point_id] << l.source_point_id if l.bidirectional
    end
    seen = Set.new
    stack = [ target_point_id ]
    while (node = stack.pop)
      return errors.add(:base, "Forma um laço com outro espelhamento deste local.") if node == source_point_id
      next unless seen.add?(node)

      stack.concat(edges[node])
    end
  end
end
