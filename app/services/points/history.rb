module Points
  # Histórico de um ponto numa janela: leituras cruas ou rollups (1h/1d).
  # `auto`: até 2 dias cru, até 31 dias por hora, depois por dia; booleano
  # é sempre cru (muda pouco e o gráfico é de faixas). No cru, a primeira
  # linha é o valor vigente no início da janela.
  class History
    RESOLUTIONS = %w[auto raw 1h 1d].freeze
    RANGES = { "24h" => 24.hours, "7d" => 7.days, "30d" => 30.days }.freeze
    LIMIT = 5000

    attr_reader :point, :from, :to, :resolution

    def initialize(point, from: nil, to: nil, resolution: nil)
      @point = point
      @to = parse(to) || Time.current
      @from = parse(from) || (@to - 24.hours)
      raise ArgumentError, "from depois de to" if @from >= @to

      @resolution = resolution.presence || "auto"
      raise ArgumentError, "resolution inválida" unless RESOLUTIONS.include?(@resolution)

      @resolution = auto if @resolution == "auto"
    end

    def raw? = resolution == "raw"

    def items
      @items ||= raw? ? readings : ReadingRollup.where(point_id: point.id, bucket: resolution, starts_at: from...to).order(:starts_at).limit(LIMIT).to_a
    end

    def truncated? = items.size >= LIMIT

    private

    def auto
      span = to - from
      return "raw" if point.bool? || span <= 2.days

      span <= 31.days ? "1h" : "1d"
    end

    def readings
      scope = Reading.where(point_id: point.id)
      first = scope.where(at: ...from).order(at: :desc).first
      first.at = from if first
      [ first, *scope.where(at: from...to).order(:at).limit(LIMIT) ].compact
    end

    def parse(value)
      return if value.blank?

      Time.zone.parse(value.to_s) or raise ArgumentError, "data inválida"
    end
  end
end
