require "shellwords"

module Points
  # Consulta sobre o conjunto de pontos de um local (Lote 4, G8; os
  # `states.*`, `label_entities`, `integration_entities` e o auto-entities do
  # HA). A mesma consulta serve à lista automática e ao contador do painel, ao
  # Liquid (`{{ "capability=onoff state=on" | points_where | size }}`), às
  # expressões (`count_points("tag=bateria below=30") > 0`) e aos sensores
  # calculados.
  #
  # Filtro = entrada em `FILTERS` (chave → lambda(consulta, ponto, valor)); filtro
  # novo é uma linha aqui, sem `case`. Valor com vírgula = qualquer um da lista.
  # Texto: `chave=valor` separados por espaço, aspas para valor com espaço
  # (`area="Sala de estar"`).
  class Query
    FILTERS = {
      "capability" => ->(_q, p, v) { list(v).include?(p.capability) },
      "device_class" => lambda { |_q, p, v|
        l = list(v)
        l.include?(p.device_class) || (p.capability == "measure" && ((l.include?("power") && p.unit == "W") || (l.include?("energy") && p.unit == "kWh")))
      },
      "area" => ->(q, p, v) { list(v).any? { |a| a == p.effective_area_id || a.casecmp?(q.area_names[p.effective_area_id].to_s) } },
      # ondaA1 (A1): no andar (o próprio andar e as áreas dentro dele), pelo nome ou id.
      "floor" => ->(q, p, v) { list(v).any? { |f| q.floor_ids(f).include?(p.effective_area_id) } },
      "quality" => ->(_q, p, v) { list(v).include?(p.quality) },
      # ondaA1 (A2): o rótulo do aparelho e da área vale para os pontos deles.
      "tag" => ->(q, p, v) { list(v).any? { |t| (tagged = q.tagged(t)).include?(p.id) || tagged.include?(p.device_id) || tagged.include?(p.effective_area_id) } },
      "state" => ->(q, p, v) { list(v).include?(q.on?(p) ? "on" : "off") },
      "is" => ->(q, p, v) { list(v).include?(q.value(p).to_s) },
      "integration" => ->(_q, p, v) { list(v).include?(p.device&.driver) },
      "device" => ->(_q, p, v) { list(v).any? { |d| p.device&.name.to_s.downcase.include?(d.downcase) } },
      "name" => ->(_q, p, v) { list(v).any? { |n| p.name.downcase.include?(n.downcase) } },
      # Pontos escolhidos pela chave (a lista fixa de entidades do HA: `['a', 'b'] | select(...)`).
      "key" => ->(_q, p, v) { list(v).include?(p.key) },
      # Pontos escolhidos pelo id (o auto-entities importado do HA: entidades fixas e as que saem).
      "id" => ->(_q, p, v) { list(v).include?(p.id) },
      "not_id" => ->(_q, p, v) { list(v).exclude?(p.id) },
      "not_integration" => ->(_q, p, v) { list(v).exclude?(p.device&.driver) },
      # O liga/desliga das automações (AutomationPoints): true = só elas; false = sem elas (as luzes de verdade).
      "automation" => ->(_q, p, v) { (p.device&.external_id == AutomationPoints::DEVICE_ID) == (v.to_s != "false") },
      # Automação que rodou nos últimos N minutos (o `last_triggered` do HA).
      "ran_min" => ->(q, p, v) { (t = q.ran_at(p)) && t > q.now - v.to_f.minutes },
      "exclude" => ->(_q, p, v) { list(v).none? { |n| "#{p.name} #{p.key} #{p.device&.name}".downcase.include?(n.downcase) } },
      "above" => ->(q, p, v) { (x = q.value(p)).is_a?(Numeric) && x > v.to_f },
      "below" => ->(q, p, v) { (x = q.value(p)).is_a?(Numeric) && x < v.to_f },
      "unchanged_min" => ->(q, p, v) { p.changed_at.nil? || p.changed_at <= q.now - v.to_f.minutes },
      "changed_min" => ->(q, p, v) { p.changed_at.present? && p.changed_at > q.now - v.to_f.minutes }
    }.freeze
    # Ordem e corte (não filtram).
    SORTS = { "name" => ->(_q, p) { p.name.downcase }, "value" => ->(q, p) { q.value(p).is_a?(Numeric) ? q.value(p) : Float::INFINITY },
              "changed_at" => ->(_q, p) { p.changed_at || Time.zone.at(0) },
              "ran_at" => ->(q, p) { q.ran_at(p) || Time.zone.at(0) } }.freeze
    OPTIONS = %w[sort limit].freeze
    KEYS = (FILTERS.keys + OPTIONS).freeze
    MAX = 500

    def self.list(v) = Array(v).flat_map { |x| x.to_s.split(",") }.map(&:strip).compact_blank

    # "capability=onoff state=on" → {"capability" => "onoff", "state" => "on"}. Chave
    # desconhecida = ArgumentError (mensagem para a tela).
    def self.parse(text)
      return text.to_h.stringify_keys if text.is_a?(Hash)

      pairs = Shellwords.split(text.to_s).map { |w| w.split("=", 2) }
      bad = pairs.reject { |k, v| KEYS.include?(k) && v.present? }.map(&:first)
      raise ArgumentError, "consulta com filtro desconhecido: #{bad.join(', ')} (use #{KEYS.join(', ')})" if bad.any?

      pairs.to_h
    rescue ::ArgumentError => e
      raise ArgumentError, e.message.start_with?("consulta") ? e.message : "consulta inválida: #{e.message}"
    end

    def self.error(text)
      parse(text)
      nil
    rescue ArgumentError => e
      e.message
    end

    attr_reader :now

    # `points`: os do local já carregados (ou a consulta do local); `value`:
    # valor de cada ponto (a simulação passa os hipotéticos).
    def initialize(site, points: nil, value: nil, now: Time.current)
      @site = site
      @points = points
      @value = value
      @now = now
    end

    def call(q, with_state: true)
      q = self.class.parse(q)
      list = all.reject { |p| p.hidden || p.disabled }
      q.each do |k, v|
        next if OPTIONS.include?(k) || (!with_state && k == "state")

        f = FILTERS[k] or next
        list = list.select { |p| f.call(self, p, v) }
      end
      list = sort(list, q["sort"])
      q["limit"].present? ? list.first(q["limit"].to_i.clamp(1, MAX)) : list
    end

    def sort(list, key)
      return list if key.blank?

      by = SORTS[key.delete_prefix("-")] or return list
      list = list.sort_by { |p| by.call(self, p) }
      key.start_with?("-") ? list.reverse : list
    end

    def value(p) = @value ? @value.call(p) : p.value
    def on?(p) = [ true, "open" ].include?(value(p))
    def all = @all ||= (@points || @site.points.includes(:device)).to_a
    def area_names = @area_names ||= @site.areas.pluck(:id, :name).to_h

    def floor_ids(ref)
      (@floors ||= {})[ref.to_s.downcase] ||= begin
        rows = @site.areas.pluck(:id, :parent_id, :name, :kind)
        floor = rows.find { |id, _, name, kind| kind == "floor" && (id == ref || name.casecmp?(ref.to_s)) }
        floor ? Area.subtree_ids(rows.map { |r| r.first(2) }, floor.first) : Set.new
      end
    end
    # Última execução da automação do ponto (AutomationPoints: `address.automation_id`).
    def ran_at(p)
      id = p.address.to_h["automation_id"] or return nil
      (@runs ||= @site.automations.pluck(:id, :last_run_at).to_h)[id]
    end

    def tagged(name) = (@tags ||= {})[name.to_s.downcase] ||= Tagging.joins(:tag).where(tags: { name: name.to_s.downcase }, taggable_type: %w[Point Device Area]).pluck(:taggable_id).to_set

    # Liquid: `{{ "tag=bateria below=30" | points_where | map: "name" | join: ", " }}`.
    # Cada ponto vem como no `points[...]` das automações.
    module LiquidFilter
      def points_where(input)
        ctx = @context.registers[:automation_context] or raise Liquid::Error, "points_where fora de um texto do local"
        ctx.query(input).map { |p| ctx.point_drop(p) }
      rescue ArgumentError => e
        raise Liquid::Error, e.message
      end
    end
  end
end
