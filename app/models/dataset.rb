# Conjunto de dados do local (Lote 2, G13): uma "tabela" que as automações
# gravam ("Registrar dados") e leem ("Consultar dados", helper Consulta),
# no lugar do SQLite + shell_command + sensor sql do HA. Campos tipados
# opcionais (`fields` = [{name, type}]); sem campos, guarda livre (jsonb,
# número reconhecido). Retenção em dias (nulo = guarda tudo), aplicada todo
# dia pelo ReadingsMaintenanceJob.
class Dataset < ApplicationRecord
  acts_as_tenant :tenant

  FIELD_TYPES = { "text" => "Texto", "number" => "Número", "bool" => "Sim/não", "time" => "Data e hora" }.freeze
  TYPE_ALIASES = { "texto" => "text", "numero" => "number", "número" => "number", "sim/nao" => "bool", "sim/não" => "bool",
                   "data" => "time", "hora" => "time" }.freeze
  FIELD = /\A[a-z_][a-z0-9_]{0,39}\z/
  MAX_FIELDS = 30
  MAX_VALUE = 2_000
  NUMBER = /\A-?\d+(?:[.,]\d+)?\z/

  belongs_to :site
  has_many :records, class_name: "DatasetRecord", dependent: nil # cascade no banco

  validates :name, presence: true, length: { maximum: 80 }
  validates :key, presence: true, uniqueness: { scope: :site_id }, format: { with: FIELD }
  validates :retention_days, numericality: { only_integer: true, in: 1..3650 }, allow_nil: true
  validate :fields_shape

  normalizes :name, with: ->(v) { v.to_s.squish }
  before_validation { self.key = name.to_s.parameterize(separator: "_").first(40).presence if key.blank? }

  def free? = fields.blank?
  def field_names = fields.pluck("name")
  def field_type(name) = fields.find { |f| f["name"] == name.to_s }&.dig("type")

  # "nome: tipo" por linha.
  def fields_text = fields.map { |f| "#{f['name']}: #{FIELD_TYPES[f['type']]&.downcase || f['type']}" }.join("\n")

  def fields_text=(text)
    self.fields = text.to_s.lines.map(&:strip).compact_blank.map do |line|
      name, type = line.split(":", 2).map { |s| s.to_s.strip.downcase }
      { "name" => name, "type" => FIELD_TYPES.key?(type) ? type : TYPE_ALIASES.fetch(type.to_s, type.presence || "text") }
    end
  end

  # Valores (texto do Liquid ou já no tipo) → linha no tipo de cada campo.
  # Campo desconhecido num conjunto tipado = ArgumentError.
  def cast(values)
    values = values.to_h.transform_keys(&:to_s)
    raise ArgumentError, "nenhum valor." if values.empty?
    raise ArgumentError, "campos demais (até #{MAX_FIELDS})." if values.size > MAX_FIELDS

    unknown = free? ? values.keys.grep_v(FIELD) : values.keys - field_names
    raise ArgumentError, "campo desconhecido: #{unknown.join(', ')}." if unknown.any?

    values.to_h { |k, v| [ k, cast_value(free? ? nil : field_type(k), v) ] }
  end

  def record!(values, run: nil)
    row = records.create!(data: cast(values), automation_run_id: run&.id, created_at: Time.current)
    HelperTypes.refresh_dependents(site_id, [ id ])
    row
  end

  # Retenção de todos os conjuntos (job diário, sem empresa atual).
  def self.purge_old!
    ActsAsTenant.without_tenant do
      where.not(retention_days: nil).find_each do |ds|
        DatasetRecord.where(dataset_id: ds.id).where(created_at: ...ds.retention_days.days.ago).delete_all
      end
    end
  end

  private

  def cast_value(type, v)
    return nil if v.nil? || v == ""

    case type
    when "number" then v.is_a?(Numeric) ? v : Float(v.to_s.strip.tr(",", "."), exception: false)&.then { |n| n % 1 == 0 ? n.to_i : n } || raise(ArgumentError, "\"#{v.to_s.truncate(30)}\" não é número.")
    when "bool" then ActiveModel::Type::Boolean.new.cast(v)
    when "time" then (v.respond_to?(:iso8601) ? v : Time.zone.parse(v.to_s))&.iso8601 || raise(ArgumentError, "\"#{v.to_s.truncate(30)}\" não é data.")
    when "text" then v.to_s.truncate(MAX_VALUE)
    else v.is_a?(String) && NUMBER.match?(v.strip) ? cast_value("number", v) : (v.is_a?(String) ? v.truncate(MAX_VALUE) : v)
    end
  end

  def fields_shape
    list = Array(fields)
    errors.add(:fields, "até #{MAX_FIELDS} campos.") if list.size > MAX_FIELDS
    bad = list.find { |f| !FIELD.match?(f["name"].to_s) || !FIELD_TYPES.key?(f["type"]) }
    errors.add(:fields, "inválido: \"#{bad['name']}: #{bad['type']}\" (use nome: texto, número, sim/não ou data).") if bad
    errors.add(:fields, "com nome repetido.") if list.pluck("name").uniq.size != list.size
  end
end
