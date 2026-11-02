module DevTools
  # Estatísticas de longo prazo (a aba "Estatísticas" das ferramentas do HA):
  # lista os resumos por hora de cada ponto, aponta os órfãos (ponto sem
  # gravar mais) e corrige: ajustar a soma de uma hora (o dia é refeito a
  # partir das horas) e apagar o resumo de um ponto.
  module Statistics
    LIMIT = 500

    Row = Data.define(:point, :hours, :first_at, :last_at) do
      # Órfão = o resumo continua lá, mas o ponto não grava mais (desligado ou sem histórico).
      def issue = point.disabled? || point.history == "none" ? "orphan" : nil
    end

    module_function

    def list(site)
      stats = ReadingRollup.joins(:point).where(points: { site_id: site.id }, bucket: "1h").group(:point_id)
                           .order("max(starts_at) DESC").limit(LIMIT).pluck(:point_id, Arel.sql("count(*)"), Arel.sql("min(starts_at) AS first_at"), Arel.sql("max(starts_at) AS last_at"))
      points = site.points.where(id: stats.map(&:first)).includes(:device).index_by(&:id)
      stats.filter_map { |id, n, first, last| points[id] && Row.new(point: points[id], hours: n, first_at: first, last_at: last) }
    end

    # Troca a soma da hora `at` (que precisa existir) e refaz o dia que ela toca.
    def adjust!(point, at, sum)
      hour = Time.zone.parse(at.to_s)&.beginning_of_hour or raise ArgumentError, I18n.t("dev_tools.stats.bad_hour")
      value = Float(sum.to_s.tr(",", "."), exception: false) or raise ArgumentError, I18n.t("dev_tools.stats.bad_sum")
      n = ReadingRollup.where(point_id: point.id, bucket: "1h", starts_at: hour).update_all(sum: value)
      raise ArgumentError, I18n.t("dev_tools.stats.no_hour") if n.zero?

      day = hour.beginning_of_day
      RollupReadingsJob.new.daily(day, day + 1.day)
      hour
    end

    def purge!(point) = ReadingRollup.where(point_id: point.id).delete_all
  end
end
