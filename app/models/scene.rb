# Cena (ESQUEMA-V1 §4.5): conjunto de comandos com nome, acionado pela web,
# pela API ou por uma agenda. `items` = [{point_id, command, value}] (o comando
# no lugar do valor do esquema: "toggle", "pulse" e "press" não são valor).
class Scene < ApplicationRecord
  include Auditable

  acts_as_tenant :tenant

  belongs_to :site
  has_many :schedules, dependent: nil # cascade no banco

  validates :name, presence: true
  validate :items_fit

  normalizes :name, with: ->(v) { v.to_s.squish }

  audited_attributes :name, :items

  # Formulário e API: descarta linha sem ponto e guarda só as chaves conhecidas.
  def items=(list)
    list = list.values if list.is_a?(Hash) || list.is_a?(ActionController::Parameters)
    super(Array(list).map { |i| i.to_h.stringify_keys.slice("point_id", "command", "value") }
                     .select { |i| i["point_id"].present? }
                     .map { |i| i.merge("value" => i["value"].presence) })
  end

  def points = Point.where(id: items.pluck("point_id")).index_by(&:id)

  # Risco mais alto entre os pontos: define quem pode acionar.
  def risk = points.values.map(&:risk).max_by { |r| Point::RISKS.keys.index(r) } || "normal"

  # Aciona tudo; um ponto com problema não impede os outros. Devolve os
  # comandos criados e os erros ("Ponto: motivo").
  def activate!(source:, user: Current.user)
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
    return errors.add(:items, "precisa de pelo menos um comando") if items.empty?

    by_id = points
    items.each do |i|
      point = by_id[i["point_id"]]
      next errors.add(:items, "tem ponto de outro local") unless point&.site_id == site_id
      next if Points::Command::COMMANDS.fetch(point.capability, []).include?(i["command"]) && point.writable

      errors.add(:items, "tem comando inválido para #{point.name}")
    end
  end
end
