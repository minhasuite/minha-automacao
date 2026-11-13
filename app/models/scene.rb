# Cena (ESQUEMA-V1 §4.5): conjunto de comandos com nome, acionado pela web,
# pela API ou por uma agenda. `items` = [{point_id, command, value}] (o comando
# no lugar do valor do esquema: "toggle", "pulse" e "press" não são valor).
class Scene < ApplicationRecord
  include Auditable
  include AlexaExposable
  include Labelable

  acts_as_tenant :tenant

  belongs_to :site
  has_many :schedules, dependent: nil # cascade no banco

  validates :name, presence: true
  validate :items_fit

  normalizes :name, with: ->(v) { v.to_s.squish }
  normalizes :category, with: ->(v) { v.to_s.squish.presence }

  audited_attributes :name, :items, :alexa_exposed, :shadow

  # Formulário e API: descarta linha sem ponto e guarda só as chaves conhecidas.
  def items=(list)
    list = list.values if list.is_a?(Hash) || list.is_a?(ActionController::Parameters)
    super(Array(list).map { |i| i.to_h.stringify_keys.slice("point_id", "command", "value") }
                     .select { |i| i["point_id"].present? }
                     .map { |i| i.merge("value" => i["value"].presence) })
  end

  def points = Point.where(id: items.pluck("point_id")).index_by(&:id)

  # Estado atual do ponto → linha da cena que o recoloca nesse valor ("Capturar
  # estado agora", F8f). Só lê; nil = sem valor ou sem comando que o reponha.
  def self.capture(point)
    v = point.value
    return if v.nil? || point.quality != "good"

    cmds = Points::Command.commands_for(point)
    item = if [ true, false ].include?(v) && (cmds & %w[on off]).size == 2 then { "command" => v ? "on" : "off" }
    elsif cmds.include?("set") && !v.is_a?(Hash) then { "command" => "set", "value" => v }
    elsif cmds.include?("select") then { "command" => "select", "value" => v.to_s }
    end
    item&.merge("point_id" => point.id)
  end

  # Risco mais alto entre os pontos: define quem pode acionar.
  def risk = Scene.max_risk(points.values.map(&:risk))
  # O maior risco da lista (o painel passa os riscos dos pontos que já tem na memória).
  def self.max_risk(risks) = risks.max_by { |r| Point::RISKS.keys.index(r) } || "normal"

  # Aciona tudo; um ponto com problema não impede os outros. Devolve os
  # comandos criados e os erros ("Ponto: motivo").
  # Em sombra (F10): cada comando fica registrado e nenhum sai.
  def activate!(source:, user: Current.user)
    Event.create!(tenant_id: tenant_id, site_id: site_id, kind: "scene", source: source, at: Time.current,
                  payload: { scene_id: id, name: name, user_id: user&.id, shadow: Shadow.active?(self) })
    return Shadow.within(site_id: site_id, scene: self) { send_items(source, user) } if Shadow.active?(self)

    send_items(source, user)
  end

  def send_items(source, user)
    by_id = points
    failures = []
    commands = items.filter_map do |i|
      point = by_id[i["point_id"]]
      next failures.push("Ponto removido da cena") && nil unless point

      Points::Command.call(point, i["command"], i["value"], source: source, user: user)
    rescue Points::Command::Error => e
      failures << "#{point.name}: #{e.message}"
      nil
    end
    [ commands, failures ]
  end

  private

  def items_fit
    return errors.add(:items, :none) if items.empty?

    by_id = points
    items.each do |i|
      point = by_id[i["point_id"]]
      next errors.add(:items, :other_site) unless point&.site_id == site_id
      next if Points::Command.commands_for(point).include?(i["command"]) && point.writable

      errors.add(:items, :bad_command, name: point.name)
    end
  end
end
