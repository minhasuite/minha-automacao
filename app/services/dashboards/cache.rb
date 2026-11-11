module Dashboards
  # Cache curto do painel (Performance 1 e 5), na memória do processo:
  #
  # - `points(site)`: as linhas de pontos e aparelhos do local (o que o
  #   Resolver lia a cada recarga de widget: ~500 pontos com aparelho). Fica
  #   guardado o resultado cru do banco, congelado, e cada pedido monta os
  #   próprios objetos (barato; o Resolver mexe no valor do ponto no
  #   `Points::Inflight.as_expected`, então nada de objeto compartilhado).
  # - `resolved(dashboard, role:)`: o painel resolvido por painel + papel +
  #   idioma + minuto (o `visible_if` por hora e o tema da noite viram no
  #   minuto), por no máximo RESOLVED_TTL.
  #
  # As duas chaves levam o carimbo do local (`stamp`): qualquer ponto,
  # aparelho, área, comando recente ou alerta gravado muda o carimbo, e o
  # valor velho nunca volta. Pontos, aparelhos e áreas pelo `xmin` das linhas
  # (a versão da linha no Postgres): pega também o `update_column`, que não
  # mexe no `updated_at`. O que o painel lê de outras tabelas (histórico
  # do gráfico, agenda, diário) fica no máximo RESOLVED_TTL atrasado.
  module Cache
    RESOLVED_TTL = 60.seconds
    STORE = ActiveSupport::Cache::MemoryStore.new(size: 64.megabytes)
    # Linhas dos pontos: uma entrada por local (a do carimbo novo troca a velha).
    ROWS = Concurrent::Map.new

    module_function

    # Carimbo do local numa consulta só (~0,3 ms): [pontos, aparelhos, áreas, comandos recentes, alertas].
    def stamp(site)
      sql = <<~SQL.squish
        SELECT (SELECT concat(count(*), '/', sum(xmin::text::bigint)) FROM points WHERE site_id = :site),
               (SELECT concat(count(*), '/', sum(xmin::text::bigint)) FROM devices WHERE site_id = :site),
               (SELECT concat(count(*), '/', sum(xmin::text::bigint)) FROM areas WHERE site_id = :site),
               (SELECT max(updated_at) FROM commands WHERE tenant_id = :tenant AND site_id = :site AND created_at > :since),
               (SELECT max(updated_at) FROM alerts WHERE site_id = :site)
      SQL
      row = ActiveRecord::Base.connection.select_rows(
        ActiveRecord::Base.sanitize_sql([ sql, { site: site.id, tenant: site.tenant_id, since: ::Command::TTL.ago } ])
      ).first
      row.map(&:to_s).join("|")
    end

    # Pontos do local (com o aparelho já carregado), ordenados pelo nome, como o
    # `site.points.includes(:device).order(:name)` de antes.
    def points(site)
      key = stamp(site).split("|").first(2).join("|")
      hit = ROWS[site.id]
      rows = hit && hit[0] == key ? hit[1] : load_rows(site, key)
      devices = rows[:devices].map { |r| Device.instantiate(r) }.index_by(&:id)
      rows[:points].map do |r|
        Point.instantiate(r).tap { |p| p.association(:device).target = devices[p.device_id] }
      end
    end

    def load_rows(site, key)
      conn = ActiveRecord::Base.connection
      frozen = ->(rel) { conn.select_all(rel.to_sql).to_a.each { |h| h.each_value(&:freeze) }.each(&:freeze).freeze }
      # O local já limita a empresa (o Resolver pode ser lido fora do `with_tenant`).
      rows = ActsAsTenant.without_tenant { { points: frozen.(Point.where(site_id: site.id).order(:name)), devices: frozen.(Device.where(site_id: site.id)) } }
      ROWS[site.id] = [ key, rows ]
      rows
    end

    # Painel resolvido (o mesmo hash do `Resolver#call`). Rascunho/prévia não passa por aqui.
    def resolved(dashboard, role:)
      return Resolver.new(dashboard, role: role).call unless enabled?

      key = [ "painel", dashboard.id, dashboard.updated_at.to_f, dashboard.version, role, I18n.locale, Time.current.to_i / 60, stamp(dashboard.site) ].join(":")
      hit = STORE.read(key) and return hit

      Resolver.new(dashboard, role: role).call.tap do |payload|
        STORE.write(key, payload, expires_in: RESOLVED_TTL)
      rescue TypeError => e # algo no `data` de um widget que não se copia: só não guarda
        Rails.logger.warn("[painel] cache: #{e.message}")
      end
    end

    # Nos testes o painel resolvido não fica guardado (cada exemplo mexe no
    # banco por fora do carimbo); o spec do cache liga com `enabled = true`.
    def enabled? = @enabled.nil? ? !Rails.env.test? : @enabled
    def enabled=(on)
      @enabled = on
    end

    def clear!
      STORE.clear
      ROWS.clear
    end
  end
end
