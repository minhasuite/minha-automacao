# Ponto: o centro de tudo (ESQUEMA-V1 §4.2). Um valor lido ou comandado de um
# dispositivo, com capacidade (§4.3), calibração, risco e o último valor.
class Point < ApplicationRecord
  include Auditable
  include AlexaExposable

  acts_as_tenant :tenant

  # §4.3 sem `machine` (v1.1); counter, timer e datetime vêm dos helpers (F8e).
  # Capacidade → tipo do valor.
  CAPABILITIES = {
    "onoff" => "bool", "dimmer" => "integer", "color" => "json", "gate" => "enum",
    "contact" => "bool", "motion" => "bool", "tamper" => "bool", "problem" => "bool",
    "measure" => "decimal", "enum" => "enum", "setpoint" => "decimal", "command" => nil,
    "text" => "string", "vacuum" => "enum", "speaker" => "json", "stream" => "string",
    "climate" => "json", "event" => "json", "counter" => "integer", "timer" => "enum", "datetime" => "string",
    "script" => nil, "calendar" => "json", "weather" => "enum", "media" => "json", "remote" => "json"
  }.freeze
  CAPABILITY_LABELS = {
    "onoff" => "Liga/desliga", "dimmer" => "Intensidade", "color" => "Cor", "gate" => "Portão",
    "contact" => "Sensor de abertura", "motion" => "Sensor de movimento", "tamper" => "Violação",
    "problem" => "Problema", "measure" => "Medição", "enum" => "Seleção", "setpoint" => "Valor ajustável",
    "command" => "Botão", "text" => "Texto", "vacuum" => "Robô aspirador", "speaker" => "Alto-falante",
    "stream" => "Câmera", "climate" => "Clima", "event" => "Evento",
    "counter" => "Contador", "timer" => "Temporizador", "datetime" => "Data e hora", "script" => "Script", "calendar" => "Agenda", "weather" => "Clima",
    "media" => "Mídia", "remote" => "Controle remoto"
  }.freeze
  # Só leitura por natureza (o resto nasce gravável).
  READ_ONLY = %w[contact motion tamper problem measure stream event calendar weather].freeze
  DATA_TYPES = %w[bool integer decimal enum string json timestamp].freeze
  STATE_CLASSES = %w[measurement total total_increasing].freeze
  HISTORY = %w[none on_change interval].freeze
  RISKS = { "normal" => "Normal", "sensitive" => "Sensível", "critical" => "Crítico" }.freeze
  QUALITIES = %w[good stale unavailable error].freeze

  belongs_to :site
  belongs_to :device
  belongs_to :area, optional: true
  has_many :commands, dependent: nil # cascade no banco
  has_many :events, dependent: nil
  has_many :notify_rules, dependent: nil
  has_many :alert_rules, dependent: nil
  has_many :schedules, dependent: nil

  before_validation :fill_defaults, on: :create

  validates :name, :key, presence: true
  validates :key, uniqueness: { scope: :site_id }, format: { with: /\A[a-z0-9_]+(\.[a-z0-9_]+)*\z/ }
  validates :capability, inclusion: { in: CAPABILITIES.keys }
  validates :data_type, inclusion: { in: DATA_TYPES }, allow_nil: true
  validates :state_class, inclusion: { in: STATE_CLASSES }, allow_nil: true
  validates :history, inclusion: { in: HISTORY }
  validates :risk, inclusion: { in: RISKS.keys }
  validates :quality, inclusion: { in: QUALITIES }
  validates :scale, :offset, numericality: true
  validates :pulse_ms, :max_on_s, :history_interval_s, :retention_days, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validates :helper, inclusion: { in: ->(_) { HelperTypes.keys } }, allow_nil: true
  validate :same_site
  validate :options_list
  validate :range_order

  normalizes :name, with: ->(v) { v.to_s.squish }
  normalizes :key, with: ->(v) { v.to_s.strip.downcase.presence }
  normalizes :unit, :icon, :device_class, :confirm, :state_class, :data_type, with: ->(v) { v.to_s.strip.presence }

  audited_attributes :name, :key, :risk, :capability, :alexa_exposed

  scope :ordered, -> { order(:name) }
  scope :helpers, -> { where.not(helper: nil) }

  def capability_label = CAPABILITY_LABELS.fetch(capability, capability)
  def risk_label = RISKS.fetch(risk, risk)
  def effective_area_id = area_id || device&.area_id

  # Nome para mostrar fora da página do aparelho (Início, listas, Alexa, app):
  # [título, contexto]. Regra de exibição, não renomeia nada:
  # - helper não leva o aparelho virtual que o guarda;
  # - um nome já contido no outro ("PIS Ilum Interna" e "Iluminação Interna") não repete;
  # - nome genérico do ponto (o rótulo da capacidade, "Interruptor 3", uma medição)
  #   cede o título ao aparelho;
  # - senão o ponto é o título e o aparelho, o contexto.
  def display_names
    dev = device&.name.to_s
    return [ name, nil ] if helper.present? || dev.blank? || Point.covered?(name, dev) || Point.covered?(dev, name)
    return [ dev, (name unless name.casecmp?(capability_label)) ] if generic_name?

    [ name, dev ]
  end

  def generic_name? = name.casecmp?(capability_label) || capability == "measure" || name.match?(/\A\D{1,20}\s\d{1,2}\z/)

  # Todas as palavras de `a` aparecem em `b` (sem acento e caixa; "Ilum" vale por "Iluminação").
  def self.covered?(a, b)
    wa, wb = [ a, b ].map { |s| I18n.transliterate(s.to_s).downcase.scan(/[a-z0-9]+/) }
    wa.any? && wa.all? { |w| wb.any? { |x| x == w || ([ w.size, x.size ].min >= 3 && (x.start_with?(w) || w.start_with?(x))) } }
  end

  def option_values = Array(options).map(&:to_s)
  def numeric? = data_type.in?(%w[integer decimal])
  def bool? = data_type == "bool"
  # Plugin do helper (F8e); nil = ponto comum.
  def helper_type = HelperTypes.for(self)

  # Único caminho de valor novo (driver, comando virtual): grava o ponto, a
  # leitura de histórico, o evento de qualidade e avisa as telas abertas.
  def report!(new_value, quality: "good", at: Time.current)
    # Evento (botão, campainha) conta a cada aviso, mesmo repetido ("clique" de novo).
    value_changed = new_value != value || (capability == "event" && !new_value.nil?)
    value_was = value
    quality_was = self.quality
    self.changed_at = at if value_changed
    update!(value: new_value, quality: quality, reported_at: at)
    PointHoldJob.schedule(self) if new_value == true && address["hold_s"].present? # sensor de pulso (movimento da câmera)
    Reading.record!(self, at) if value_changed
    if quality != quality_was
      events.create!(site: site, kind: "quality", payload: { from: quality_was, to: quality }, at: at)
    end
    if value_changed || quality != quality_was || capability == "command"
      broadcast_refresh_to(self)
      # Dashboards: um aviso por local só com o id do ponto; cada tela recarrega
      # os widgets que dependem dele (Turbo Frame, com o papel de quem vê).
      Turbo::StreamsChannel.broadcast_action_to(site, :points, action: :point_changed, target: id)
    end
    Automations.on_change(self, quality_was, value_was) if value_changed
    # Só a qualidade mudou (caiu, voltou): os helpers calculados também refazem (Pacote 2).
    HelperTypes.on_change(self) if !value_changed && quality != quality_was
  end

  # Onde estes pontos aparecem: [rótulo, registro] (dispositivo e helper).
  def self.usages(site, points)
    ids = points.pluck(:id, :key).flatten.compact
    return [] if ids.empty?

    like = ids.map { |v| "%#{sanitize_sql_like(v)}%" }
    point_ids = points.pluck(:id)
    [
      [ "Painel", site.dashboards.where("definition::text LIKE ANY (ARRAY[?])", like) ],
      [ "Automação", site.automations.where("definition::text LIKE ANY (ARRAY[?])", like) ],
      [ "Script", site.scripts.where("definition::text LIKE ANY (ARRAY[?])", like) ],
      [ "Cena", site.scenes.where("items::text LIKE ANY (ARRAY[?])", like) ],
      [ "Espelhamento", site.point_links.where(source_point_id: point_ids).or(site.point_links.where(target_point_id: point_ids)) ],
      [ "Aviso", site.notify_rules.where(point_id: point_ids) ],
      [ "Alerta", site.alert_rules.where(point_id: point_ids) ],
      [ "Agenda", site.schedules.where(point_id: point_ids) ],
      [ "Helper", HelperTypes.dependents(site.id, point_ids) ]
    ].flat_map { |label, scope| scope.map { |r| [ label, r ] } }
  end

  # Texto do formulário ("true", "25,5", "open") → valor no tipo do ponto.
  def cast(raw)
    return raw unless raw.is_a?(String)
    return if raw.blank?
    return ActiveModel::Type::Boolean.new.cast(raw) if bool?
    return Float(raw.tr(",", "."), exception: false) || raw if numeric?

    raw
  end

  # Bruto do aparelho ↔ valor do ponto (calibração: valor = bruto × scale + offset).
  # Endereço com `decode` (mapa de dados): Points::Decode desembrulha antes (nil = ignorar).
  def from_raw(raw)
    return Points::Decode.call(address, raw) if address["decode"].present?
    return Points::Color.decode(address, raw) if address["color"].present?
    return raw unless numeric? && raw.is_a?(Numeric)

    v = (BigDecimal(raw.to_s) * scale) + offset
    data_type == "integer" ? v.round.to_i : v.to_f
  end

  # Gravações no aparelho para um valor ([[endereço, bruto]]) quando não é um
  # dp/propriedade só (Lote 8: cor = modo + cor ou temperatura). nil = o
  # driver grava `to_raw(value)` no endereço do ponto, como sempre.
  def raw_writes(value, via = nil) = address["color"].present? ? Points::Color.writes(self, value, via) : nil

  # Atributos novos (Lote 8): único caminho, dispara os gatilhos "Ponto
  # mudou" com atributo (Automations::Triggers.on_attrs_change).
  def report_attrs!(new_attrs)
    was = attrs.to_h
    return if new_attrs.to_h == was

    update_column(:attrs, new_attrs.to_h) # rubocop:disable Rails/SkipsModelValidations
    Automations::Triggers.on_attrs_change(self, was)
  end

  def to_raw(value)
    return value unless numeric?
    raise ArgumentError, "Escala zero no ponto #{key}." if scale.zero?

    ((BigDecimal(value.to_s) - offset) / scale).round.to_i
  end

  # Formulário web: "Casa, Fora, Férias" ↔ ["Casa", "Fora", "Férias"]. Lote 9:
  # uma por linha também vale (o importador do HA manda assim).
  def options_text = option_values.join(", ")
  def options_text=(text)
    self.options = text.to_s.split(/[,\n]/).map(&:strip).compact_blank
  end

  private

  def fill_defaults
    self.site_id ||= device&.site_id
    self.data_type ||= CAPABILITIES[capability]
    # `writable: false` vindo do mapa também vale (é igual ao padrão da coluna: só `came_from_user?` acusa).
    self.writable = !capability.in?(READ_ONLY) unless writable_changed? || @attributes["writable"].came_from_user? || helper
    self.min, self.max = 0, 100 if capability == "dimmer" && min.nil? && max.nil?
    self.key ||= [ device&.name, name ].map { |s| s.to_s.parameterize(separator: "_") }.compact_blank.join(".").presence
  end

  def same_site
    errors.add(:device, "precisa ser deste local") if device && device.site_id != site_id
    errors.add(:area, "precisa ser deste local") if area && area.site_id != site_id
  end

  def options_list
    errors.add(:options, "precisa ser uma lista de opções") unless options.is_a?(Array) && options.all? { |o| o.is_a?(String) && o.present? }
    errors.add(:options, "não pode ficar vazia numa seleção") if capability == "enum" && option_values.empty?
  end

  def range_order
    errors.add(:max, "precisa ser maior que o mínimo") if min && max && max <= min
  end
end
