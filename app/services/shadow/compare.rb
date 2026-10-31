module Shadow
  # Comparador da migração em sombra (F10). Para uma janela, junta o que a
  # fonte de referência fez de verdade (plugin de integração que responde a
  # `reference`; ex.: Home Assistant) com o que a sombra daqui teria feito
  # (execuções em sombra + ShadowAction) e classifica cada automação:
  # igual, MA a mais, MA a menos, diferente, sem par no MA ou sem disparo.
  # A ponte entre os dois lados é o de-para (ExternalRef da fonte):
  # automação de lá → automação daqui, entidade de lá → ponto daqui.
  class Compare
    # Execuções que passaram das condições (as que a referência também conta).
    NOT_RUN = %w[skipped loop cancelled].freeze
    ORDER = %w[different missing extra unmapped same idle].freeze

    def self.sources = Integrations.plugins.select { |p| p.respond_to?(:reference) }
    def self.source(key) = sources.find { |p| p.key == key.to_s }

    # `entries`: o que a referência devolveu, já lido (sem ir à rede).
    def self.call(site, key, from:, to:, entries: nil, integration: nil)
      plugin = source(key) or raise ArgumentError, "fonte de referência desconhecida: #{key}"
      integration ||= site.integrations.find_by(driver: plugin.driver)
      new(site, plugin, from, to).save!(plugin.reference(integration, from, to, entries: entries))
    end

    def initialize(site, plugin, from, to)
      @site = site
      @plugin = plugin
      @from = from
      @to = to
      refs = ExternalRef.where(site_id: site.id, source: plugin.key).mapped
      @automation_of = refs.where(target_type: "Automation").pluck(:external_id, :target_id).to_h
      points = refs.where(target_type: "Point").pluck(:external_id, :target_id)
      @point_of = points.to_h
      # Ponto → uma entidade de lá só (duas integrações de lá no mesmo aparelho contam como uma).
      @entity_of = points.reverse.to_h(&:reverse)
    end

    def save!(reference)
      rows = rows(reference)
      ShadowReport.create!(site: @site, source: @plugin.key, window_from: @from, window_to: @to, rows: rows,
                           summary: rows.group_by { |r| r["status"] }.transform_values(&:size))
    end

    def rows(reference)
      runs = AutomationRun.where(site_id: @site.id, shadow: true, dry_run: false, started_at: @from..@to).where.not(status: NOT_RUN)
                          .group(:automation_id).count
      actions = ShadowAction.where(site_id: @site.id, created_at: @from..@to).where.not(automation_id: nil).group_by(&:automation_id)
      names = Automation.where(id: @automation_of.values).pluck(:id, :name).to_h
      ids = (reference.keys + @automation_of.keys).uniq
      ids.map { |ext| row(ext, reference[ext] || {}, @automation_of[ext], names, runs, actions) }
         .sort_by { |r| [ ORDER.index(r["status"]), r["name"].to_s ] }
    end

    private

    def row(ext, ref, automation_id, names, runs, actions)
      base = { "ref" => ext, "name" => names[automation_id] || ref["name"] || ext, "automation_id" => automation_id,
               "ref_runs" => ref["runs"].to_i, "runs" => runs[automation_id].to_i }
      unless automation_id
        status = base["ref_runs"].positive? ? "unmapped" : "idle"
        return base.merge("status" => status, "detail" => ("Não foi importada (sem de-para)" if status == "unmapped"))
      end

      ignored, theirs = Array(ref["effects"]).map { |e, s| [ @entity_of[@point_of[e]] || e, normal(s) ] }.partition { |e, _| !@point_of.key?(e) }
      ours = Array(actions[automation_id]).flat_map { |a| a.effects.map { |fx| effect(fx) } }
      missing, extra = diff(theirs.map { |e, s| "#{e}=#{s}" }, ours)
      base.merge("status" => status(base, missing, extra), "missing" => missing, "extra" => extra,
                 "ignored" => ignored.map(&:first).uniq, "detail" => detail(base, missing, extra, ignored))
    end

    # Efeito daqui → "entidade=estado" (ponto sem par lá = "ma:<chave>").
    def effect(fx)
      entity = @entity_of[fx["point_id"]] || "ma:#{Point.where(id: fx['point_id']).pick(:key) || 'ponto removido'}"
      "#{entity}=#{normal(@plugin.state_for(fx['command'].to_s, fx['value']))}"
    end

    def normal(v) = v.to_s.match?(/\A-?\d+\.0+\z/) ? v.to_s.sub(/\.0+\z/, "") : v.to_s

    # Multiconjuntos: o que só a referência fez (missing) e o que só a sombra fez (extra). "x=*" casa com qualquer estado de x.
    def diff(theirs, ours)
      left = theirs.dup
      extra = ours.reject do |o|
        i = left.index(o) || (o.end_with?("=*") && left.index { |t| t.start_with?(o.delete_suffix("*")) })
        i && left.delete_at(i)
      end
      [ left, extra ]
    end

    def status(base, missing, extra)
      return "idle" if base["ref_runs"].zero? && base["runs"].zero? && missing.empty? && extra.empty?
      return "same" if missing.empty? && extra.empty? && base["ref_runs"] == base["runs"]
      return "extra" if missing.empty? && (extra.any? || base["runs"] > base["ref_runs"])
      return "missing" if extra.empty? && (missing.any? || base["runs"] < base["ref_runs"])

      "different"
    end

    def detail(base, missing, extra, ignored)
      parts = []
      parts << "disparos #{base['ref_runs']} na referência × #{base['runs']} na sombra" if base["ref_runs"] != base["runs"]
      parts << "só na referência: #{summary(missing)}" if missing.any?
      parts << "só na sombra: #{summary(extra)}" if extra.any?
      parts << "#{ignored.size} efeito(s) em entidade sem de-para" if ignored.any?
      parts.join("; ").presence
    end

    def summary(list) = list.tally.map { |k, n| n > 1 ? "#{k} ×#{n}" : k }.first(6).join(", ")
  end
end
