module Diagnostics
  # O que as regras olham de um local, carregado uma vez por diagnóstico:
  # aparelhos (fora os internos e os desativados), pontos, integrações,
  # ajustes, hub de cada filho, duplicados e pulos de leitura.
  class Context
    attr_reader :site, :now, :settings

    def initialize(site, now: Time.current)
      @site = site
      @now = now
      @settings = Diagnostics.settings(site)
    end

    def config = Diagnostics.config

    def devices = @devices ||= site.devices.listed.where(disabled: false).includes(:area, :integration).order(:name).to_a
    def active_devices = @active_devices ||= devices.select { |d| d.removed_at.nil? }
    def integrations = @integrations ||= site.integrations.order(:name).to_a

    def points_by_device
      @points_by_device ||= begin
        by_id = devices.index_by(&:id)
        Point.where(device_id: by_id.keys, disabled: false).includes(:area).order(:name).to_a
             .each { |p| p.device = by_id[p.device_id] }.group_by(&:device_id)
      end
    end

    def points_of(device) = points_by_device.fetch(device.id, [])
    def points = @points ||= active_devices.flat_map { |d| points_of(d) }

    # Sujeitos de uma regra (`describe subject:`).
    def subjects(kind)
      { device: devices, point: points, integration: integrations }.fetch(kind.to_sym)
    end

    # Sem sinal: status do aparelho (offline/erro).
    def offline?(device) = device.removed_at.nil? && %w[offline error].include?(device.status)

    # Desde quando está sem sinal (último contato, ou o cadastro se nunca respondeu).
    def offline_since(device) = device.last_seen_at || device.created_at

    # Hub (aparelho do mesmo local cujo external_id é o `address.via` do filho).
    def parent(device)
      via = device.address.to_h["via"].presence or return nil
      by_external[via.to_s]
    end

    def children(device) = (@children ||= active_devices.group_by { |d| parent(d)&.id })[device.id].to_a

    def by_external = @by_external ||= active_devices.select { |d| d.external_id.present? }.index_by { |d| d.external_id.to_s }

    # Filho cujo hub caiu: a culpa é do hub (um achado só, nele).
    def hub_down?(device)
      (p = parent(device)) && offline?(p)
    end

    # Integração fora e vários aparelhos dela sem sinal juntos.
    def integration_down?(integration)
      return false unless integration.status == "error"

      active_devices.count { |d| d.integration_id == integration.id && offline?(d) } >= config.fetch("integration_min_devices")
    end

    def covered?(device)
      hub_down?(device) || (device.integration && down_integration_ids.include?(device.integration_id))
    end

    def down_integration_ids = @down_integration_ids ||= integrations.select { |i| integration_down?(i) }.to_set(&:id)

    # Entrada do inventário da conta para este aparelho (mesmo external_id).
    def inventory_entry(device)
      return nil unless device.integration && device.external_id.present?

      @inventory ||= {}
      @inventory[device.integration_id] ||= device.integration.found.index_by { |e| e["id"].to_s }
      @inventory[device.integration_id][device.external_id.to_s]
    end

    # Outros aparelhos ativos que parecem o mesmo: mesmo driver e external_id,
    # ou mesmo driver e mesmo endereço de rede (campos de `duplicate_address_keys`).
    def duplicates_of(device)
      return [] if device.removed_at

      @dup_ext ||= active_devices.select { |d| d.external_id.present? }.group_by { |d| [ d.driver, d.external_id.to_s ] }
      @dup_addr ||= active_devices.select { |d| d.address.to_h["host"].present? }.group_by { |d| address_identity(d) }
      list = device.external_id.present? ? @dup_ext[[ device.driver, device.external_id.to_s ]].to_a : []
      list |= @dup_addr[address_identity(device)].to_a if device.address.to_h["host"].present?
      list - [ device ]
    end

    def address_identity(device)
      [ device.driver, device.address.to_h.slice(*config.fetch("duplicate_address_keys")).transform_values(&:to_s).sort ]
    end

    # Limiares por device_class do ponto (`sensors:` do YAML).
    def sensor(point) = config.dig("sensors", point.device_class.to_s).to_h

    # Último pulo absurdo de cada ponto com `jump` no YAML: {point_id => {from:, to:, at:, minutes:}}.
    # Uma consulta só, nas leituras das últimas `jump_lookback_hours`.
    def jumps
      @jumps ||= begin
        wanted = points.select { |p| p.capability == "measure" && sensor(p)["jump"] }
        wanted.empty? ? {} : jump_rows(wanted)
      end
    end

    private

    def jump_rows(wanted)
      values = wanted.map { |p| s = sensor(p); [ p.id, s["jump"].to_f, s.fetch("jump_minutes", 30).to_i * 60 ] }
      list = values.map { |id, j, w| ActiveRecord::Base.sanitize_sql_array([ "(?::uuid, ?::numeric, ?::integer)", id, j, w ]) }.join(", ")
      since = now - config.fetch("jump_lookback_hours").hours
      sql = ActiveRecord::Base.sanitize_sql_array([ <<~SQL.squish, since ])
        SELECT DISTINCT ON (r.point_id) r.point_id, r.prev, r.value, r.at, EXTRACT(EPOCH FROM (r.at - r.prev_at)) AS secs
        FROM (SELECT point_id, at, value, LAG(value) OVER w AS prev, LAG(at) OVER w AS prev_at
              FROM readings WHERE at >= ? AND value IS NOT NULL AND point_id IN (#{values.map { |id, _, _| ActiveRecord::Base.connection.quote(id) }.join(', ')})
              WINDOW w AS (PARTITION BY point_id ORDER BY at)) r
        JOIN (VALUES #{list}) AS t(point_id, jump, win) ON t.point_id = r.point_id
        WHERE r.prev IS NOT NULL AND ABS(r.value - r.prev) >= t.jump AND r.at - r.prev_at <= make_interval(secs => t.win)
        ORDER BY r.point_id, r.at DESC
      SQL
      ActiveRecord::Base.connection.select_all(sql).to_h do |row|
        [ row["point_id"], { from: row["prev"].to_f, to: row["value"].to_f, at: row["at"], minutes: (row["secs"].to_f / 60).round } ]
      end
    end
  end
end
