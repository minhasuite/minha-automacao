# Rótulos (labels do HA; Tag/Tagging de sempre) em qualquer modelo: ponto,
# aparelho, área, cena, automação e script (ondaA1, A2). Modelo novo que
# aceita rótulo = `include Labelable`. O rótulo do aparelho e da área vale
# para os pontos dele na consulta `tag=` (Points::Query).
module Labelable
  extend ActiveSupport::Concern

  MAX = 10

  included do
    has_many :taggings, as: :taggable, dependent: :delete_all
    has_many :tags, through: :taggings

    scope :labeled, ->(name) { where(id: Tagging.joins(:tag).where(taggable_type: base_class.name, tags: { name: name.to_s.downcase }).select(:taggable_id)) }
  end

  class_methods do
    # Rótulos usados nos registros da consulta (para o filtro da lista).
    def labels_in(scope) = Tag.joins(:taggings).where(taggings: { taggable_type: base_class.name, taggable_id: scope.select(:id) }).distinct.order(:name).pluck(:name)
  end

  def label_names = tags.map(&:name).sort
  def label_list = label_names.join(", ")

  def label_list=(text)
    names = text.to_s.split(",").map { |n| n.squish.downcase }.compact_blank.uniq.first(MAX)
    self.tags = names.map { |n| Tag.find_or_create_by!(name: n) }
  end
end
