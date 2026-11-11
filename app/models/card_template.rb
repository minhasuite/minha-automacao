# Modelo de card do local (P1.3): dado puro, resolvido pelo
# `Dashboards::CardTemplates` (desenho do componentes-ui, espaços em Liquid,
# consulta ou regra, toque pelo `Dashboards::Actions`). Mudar desenho,
# espaços ou entradas sobe a `version`. `source` = "package:<chave>" quando
# veio de um pacote (o pacote atualiza e remove só os dele).
class CardTemplate < ApplicationRecord
  include Auditable

  acts_as_tenant :tenant

  belongs_to :site

  validates :key, uniqueness: { scope: :site_id }
  validate :template_valid

  audited_attributes :key, :version

  before_update { self.version += 1 if (changed & %w[layout slots params]).any? }

  def to_template
    { "key" => key, "name" => name, "description" => description, "layout" => layout, "slots" => slots.to_h,
      "params" => Array(params), "version" => version, "id" => id, "source" => source }
  end

  # Cópia editável de um modelo (do local ou embutido), com chave livre.
  def self.duplicate!(site, template)
    base = template["key"].to_s.sub(/-\d+\z/, "").first(34)
    key = (2..99).lazy.map { |n| "#{base}-#{n}" }.find { |k| !site.card_templates.exists?(key: k) && !Dashboards::CardTemplates.builtin(k) }
    params = Array(template["params"]).map { |p| p.merge("label" => Dashboards::CardTemplates.param_label(p)) }
    site.card_templates.create!(key: key, name: I18n.t("dashboards.copy_name", name: Dashboards::CardTemplates.name(template)).first(80),
                                description: Dashboards::CardTemplates.loc(template["description"]).presence, layout: template["layout"],
                                slots: template["slots"], params: params)
  end

  private

  def template_valid
    Dashboards::CardTemplates.errors(to_template).first(5).each { |e| errors.add(:base, e) }
  end
end
