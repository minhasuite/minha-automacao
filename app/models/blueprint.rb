# Blueprint (F8f): modelo de automação ou script com entradas tipadas
# (`inputs`: key, label, type, default, required, description, options,
# filter {capability, writable, area}). A definição é a DSL de sempre com
# `{"!input": "chave"}` no lugar do valor; `instantiate` troca pelas
# entradas. A automação criada guarda o vínculo e as entradas: mudar a
# definição, as entradas ou o modo sobe a `version` e refaz o rascunho das
# automações ligadas (elas mostram o aviso até publicar).
#
# `source`: "builtin:<chave>" (config/blueprints, Blueprints.sync_builtin!),
# "ha" (importado do Home Assistant, Blueprints::HaImport) ou "manual".
class Blueprint < ApplicationRecord
  include Auditable

  acts_as_tenant :tenant

  INPUT_TYPES = LocalizedLabel.for("automations.labels.input_types", %w[point number text boolean select duration time scene])
  # Entrada que escolhe um registro do local (Lote 5: a cena do `scene.turn_on`
  # importado do HA): tipo → associação do Site. Tipo novo = uma linha aqui.
  RECORD_INPUTS = { "scene" => :scenes }.freeze
  # Entrada dentro de texto ou expressão (Lote 5): `[[chave]]` vira a `key`
  # do ponto escolhido (ou o valor da entrada), ao criar a automação.
  INLINE_INPUT = /\[\[([a-z0-9_]+)\]\]/
  SOURCES = LocalizedLabel.for("automations.labels.blueprint_sources", %w[builtin ha manual package])

  belongs_to :site
  has_many :automations, dependent: nil # o banco solta o vínculo (nullify)

  validates :name, presence: true
  validates :domain, inclusion: { in: Automation::KINDS.keys }
  validates :mode, inclusion: { in: Automation::MODES.keys }
  validate :inputs_valid
  validate { errors.add(:definition, :not_object) unless definition.is_a?(Hash) }

  normalizes :name, with: ->(v) { v.to_s.squish }

  audited_attributes :name, :version

  before_update { self.version += 1 if will_save_change_to_definition? || will_save_change_to_inputs? || will_save_change_to_mode? }
  after_update :propagate!, if: :saved_change_to_version?

  scope :ordered, -> { order(:name) }

  def builtin? = source.start_with?("builtin:")
  def source_label = SOURCES.fetch(source.split(":").first, source)
  def domain_label = Automation::KINDS.fetch(domain, domain)
  def required?(input) = input["required"] != false && !input.key?("default")

  # Entradas (texto do formulário ou valores) → [definição, entradas limpas, erros].
  def instantiate(raw)
    raw = raw.to_h.stringify_keys
    errors = []
    values = inputs.to_h do |input|
      v = raw[input["key"]]
      v = input["default"] if v.nil? || v == ""
      [ input["key"], v.nil? || v == "" ? nil : cast(input, v, errors) ]
    end
    inputs.each { |input| errors << I18n.t("automations.blueprint_errors.missing", field: input["label"].to_s.downcase) if values[input["key"]].nil? && required?(input) }
    keys = site.points.where(id: values.values.grep(Automation::UUID)).pluck(:id, :key).to_h
    [ replace(definition.deep_dup, values, keys), values.compact, errors ]
  end

  # Automação (ou script) nova a partir das entradas. Publicada se a DSL
  # fechar (e `publish`); senão fica no rascunho com os erros no editor.
  # Nasce desligada.
  def create_automation!(name:, values:, area_id: nil, publish: true)
    definition, clean, errors = instantiate(values)
    raise ArgumentError, errors.to_sentence if errors.any?

    scope = domain == "script" ? site.scripts : site.automations
    Automation.transaction do
      a = scope.create!(name: name.presence || self.name, description: description, mode: mode, area_id: area_id.presence,
                        blueprint: self, blueprint_inputs: clean, draft: definition)
      a.publish!(a.draft) if publish && a.errors_in(a.draft).empty?
      a
    end
  end

  # Mudou o blueprint: refaz o rascunho de cada automação ligada (com as
  # mesmas entradas). A versão publicada só muda quando alguém publicar.
  def propagate!
    automations.find_each { |a| rebuild_draft!(a) }
  end

  def rebuild_draft!(automation)
    definition, _clean, errors = instantiate(automation.blueprint_inputs)
    automation.update!(draft: definition) if errors.empty?
    errors
  end

  private

  def cast(input, v, errors)
    label = input["label"]
    case input["type"]
    when "point" then point_input(input, v.to_s, errors)
    when "number" then v.is_a?(Numeric) ? v : (Float(v.to_s.tr(",", "."), exception: false)&.then { |n| n % 1 == 0 ? n.to_i : n } || errors.push(I18n.t("automations.blueprint_errors.number", field: label)) && nil)
    when "boolean" then ActiveModel::Type::Boolean.new.cast(v)
    when "select" then v.to_s.presence_in(Array(input["options"]).map(&:to_s)) || errors.push(I18n.t("automations.blueprint_errors.option", field: label)) && nil
    when "duration" then Automations::Dsl.seconds(v) ? (v.is_a?(Numeric) ? v : v.to_s.delete(" ")) : errors.push(I18n.t("automations.blueprint_errors.duration", field: label)) && nil
    when "time" then v.to_s[0, 5].then { |t| Automations::Dsl::TIME.match?(t) ? t : errors.push(I18n.t("automations.blueprint_errors.time", field: label)) && nil }
    when *RECORD_INPUTS.keys
      scope = site.public_send(RECORD_INPUTS[input["type"]])
      (scope.find_by(id: v.to_s) if Automation::UUID.match?(v.to_s))&.id || scope.find_by(name: v.to_s)&.id || errors.push(I18n.t("automations.blueprint_errors.missing_record", field: label)) && nil
    else v.to_s.truncate(500)
    end
  end

  def point_input(input, ref, errors)
    point = site.points.includes(:area, :device).find_by(id: ref) if Automation::UUID.match?(ref)
    point ||= site.points.find_by(key: ref)
    return errors.push(I18n.t("automations.blueprint_errors.point", field: input["label"])) && nil unless point

    reason = filter_miss(input["filter"].to_h, point)
    return errors.push(I18n.t("automations.blueprint_errors.unfit", field: input["label"], name: point.name, reason: reason)) && nil if reason

    point.id
  end

  # Por que o ponto não passa no filtro da entrada (nil = passa).
  def filter_miss(filter, point)
    caps = Array(filter["capability"])
    return I18n.t("automations.blueprint_errors.capability", caps: caps.map { |c| Point::CAPABILITY_LABELS.fetch(c, c).downcase }.join(I18n.t("automations.blueprint_errors.or"))) if caps.any? && caps.exclude?(point.capability)
    return I18n.t("automations.blueprint_errors.writable") if filter["writable"] && !point.writable

    area = filter["area"].to_s.downcase.presence
    I18n.t("automations.blueprint_errors.area", area: filter["area"]) if area && Area.find_by(id: point.effective_area_id)&.name.to_s.downcase != area
  end

  # `{"!input": "k"}` → valor; entrada opcional vazia some da definição.
  # `[[k]]` num texto → `key` do ponto (ou o valor) da entrada.
  def replace(node, values, keys = {})
    case node
    when Hash
      return values[node["!input"]] if node.keys == [ "!input" ]

      node.to_h { |k, v| [ k, replace(v, values, keys) ] }.compact
    when Array then node.map { |v| replace(v, values, keys) }.compact
    when String then node.gsub(INLINE_INPUT) { (v = values[::Regexp.last_match(1)]).nil? ? ::Regexp.last_match(0) : keys.fetch(v, v).to_s }
    else node
    end
  end

  def inputs_valid
    return errors.add(:inputs, :not_list) unless inputs.is_a?(Array)

    keys = inputs.map { |i| i.is_a?(Hash) && i["key"] }
    errors.add(:inputs, :bad_key) unless keys.all? { |k| k.is_a?(String) && Automations::Dsl::VAR.match?(k) }
    errors.add(:inputs, :repeated) if keys.uniq.size != keys.size
    inputs.each do |i|
      next unless i.is_a?(Hash)

      errors.add(:inputs, :bad_type, key: i["key"]) unless INPUT_TYPES.key?(i["type"])
      errors.add(:inputs, :no_options, key: i["key"]) if i["type"] == "select" && Array(i["options"]).empty?
    end
  end
end
