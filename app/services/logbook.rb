# Diário (o Logbook do HA): uma linha do tempo de tudo o que aconteceu num
# local, juntando fontes registradas em `SOURCES` (mudanças de ponto,
# comandos, execuções, cenas, alertas, qualidade, cadastro e entradas).
# Fonte nova = classe em `Logbook::Sources` (`describe key:, label:, icon:,
# role:` e `fetch(filtro)` → itens do mais novo para o mais velho, no máximo
# `f.limit`, com `at` em `f.from...f.to`) + nome em `SOURCES`; a tela, os
# filtros, a paginação e a API não mudam.
#
# Paginação por cursor (`before` = `at` do último item da página): cada fonte
# traz até uma página antes do cursor e o Diário corta a junção.
# ponytail: itens com o mesmo `at` exato na virada da página podem pular um;
# trocar o cursor por (at, id) se aparecer.
module Logbook
  SOURCES = %w[Changes Commands Runs Scenes Alerts Quality Audit Logins].freeze
  PAGE = 40
  PERIODS = { "24h" => 24.hours, "7d" => 7.days, "30d" => 30.days, "365d" => 365.days }.freeze
  PERIOD_LABELS = LocalizedLabel.for("labels.periods", %w[24h 7d 30d 365d])

  # `state`: texto do valor novo (chip na tela); `ref`: {type, id} do que abrir.
  Item = Struct.new(:at, :source, :icon, :tone, :title, :state, :detail, :user, :point_id, :ref, keyword_init: true) do
    def as_json(*) = to_h.merge(at: at.iso8601(3)).compact.as_json
  end

  module_function

  def sources = SOURCES.map { |n| Sources.const_get(n) }
  def source(key) = sources.find { |s| s.key == key.to_s }
  # Fontes que o papel enxerga (cadastro e entradas são do técnico e do dono).
  def sources_for(role) = sources.select { |s| SiteMembership.allowed?(role, s.role) }

  # → [itens, cursor da próxima página ou nil].
  def call(f)
    list = f.sources.flat_map { |s| s.fetch(f) }.sort_by { |i| -i.at.to_f }.first(f.limit)
    [ list, (list.last.at.utc.iso8601(6) if list.size == f.limit) ]
  end

  # Valor de uma leitura de volta ao tipo do ponto (o texto vem do mesmo
  # `point_value_text` das telas).
  def value_of(point, reading)
    return reading.value.to_i == 1 if point.bool?
    return reading.value&.to_f if reading.value_text.nil? && point.numeric?
    return reading.value_text if %w[enum string].include?(point.data_type) || reading.value_text.nil?

    JSON.parse(reading.value_text)
  rescue JSON::ParserError
    reading.value_text
  end

  # Nome do ponto na linha: com o aparelho quando o ponto sozinho não diz
  # qual é ("Luz da sala", "Medidor geral · Potência"), como nas telas.
  def point_title(p)
    title, context = p.display_names
    dev = p.device&.name.to_s
    return dev if context.nil? && p.helper.blank? && dev.size > title.to_s.size && Point.covered?(title.to_s, dev)

    [ title, context ].compact.join(" · ")
  end

  def text(point, value) = ApplicationController.helpers.point_value_label(point, value)

  # Pessoas com acesso ao local (membros e administradores da instalação).
  def people(site)
    User.where(tenant_id: site.tenant_id).where(id: SiteMembership.where(site_id: site.id).select(:user_id))
        .or(User.where(tenant_id: site.tenant_id, role: %w[owner admin])).order(:name)
  end

  # Filtro da tela e da API. `to` é o cursor (exclusivo).
  class Filter
    attr_reader :site, :role, :from, :to, :area_id, :device_id, :point_id, :user_id, :q, :limit, :keys, :period

    def initialize(site:, role:, params: {}, limit: PAGE, now: Time.current)
      @site = site
      @role = role
      p = params.to_h.with_indifferent_access
      zone = ActiveSupport::TimeZone[site.timezone] || Time.zone
      @period = p[:period].presence_in(PERIODS.keys) || "7d"
      @custom = date(p[:from], zone)
      @from = @custom&.beginning_of_day || (now - PERIODS[@period])
      @until = date(p[:until], zone)&.end_of_day
      @to = [ time(p[:before]), @until, now + 1.second ].compact.min
      @area_id, @device_id, @point_id, @user_id = p.values_at(:area_id, :device_id, :point_id, :user_id).map(&:presence)
      @q = p[:q].to_s.strip.first(80).presence
      allowed = Logbook.sources_for(role).map(&:key)
      @keys = Array(p[:sources]).compact_blank & allowed
      @keys = allowed if @keys.empty?
      @limit = limit
    end

    def sources = Logbook.sources.select { |s| @keys.include?(s.key) }
    def window = from...to
    # Algum filtro de ponto (área, aparelho, ponto ou busca)?
    def narrowed? = [ area_id, device_id, point_id, q ].any?
    def custom_dates? = @custom.present? || @until.present?

    # Pontos do local que passam nos filtros de área, aparelho, ponto e busca.
    def points
      @points ||= begin
        scope = site.points
        scope = scope.where(id: point_id) if point_id
        scope = scope.where(device_id: device_id) if device_id
        scope = scope.left_joins(:device).where("points.area_id = :a OR (points.area_id IS NULL AND devices.area_id = :a)", a: area_id) if area_id
        if q
          like = "%#{ActiveRecord::Base.sanitize_sql_like(q)}%"
          scope = scope.left_joins(:device).where("points.name ILIKE :q OR points.key ILIKE :q OR devices.name ILIKE :q", q: like)
        end
        scope
      end
    end

    # Parâmetros para a próxima página (o mesmo filtro com outro cursor).
    def to_params(before = nil)
      { period: period, from: (from.to_date.iso8601 if custom_dates?), until: @until&.to_date&.iso8601, area_id: area_id, device_id: device_id,
        point_id: point_id, user_id: user_id, q: q, sources: (keys if keys.size < Logbook.sources_for(role).size), before: before }.compact
    end

    private

    def date(v, zone) = v.presence && (Date.iso8601(v.to_s) rescue nil)&.in_time_zone(zone) # rubocop:disable Style/RescueModifier
    def time(v) = v.presence && (Time.iso8601(v.to_s) rescue nil) # rubocop:disable Style/RescueModifier
  end

  module Sources
    class Base
      extend PluginTexts
      translates :label

      class << self
        attr_reader :key, :icon, :role

        def describe(key:, label:, icon:, role: :view)
          @key = key
          @label = label
          @icon = icon
          @role = role
        end

        def fetch(_f) = []
        def item(**) = Item.new(source: key, icon: icon, tone: "muted", **)
      end
    end

    # Mudanças de valor dos pontos que não são medida (como o HA: sensor
    # numérico vai para o Histórico, não para o Diário).
    class Changes < Base
      describe key: "changes", label: "Mudanças", icon: "switch-horizontal"
      texts en: { label: "Changes" }, es: { label: "Cambios" }

      def self.fetch(f)
        return [] if f.user_id

        points = f.points.where.not(data_type: %w[integer decimal]).where.not(capability: %w[stream calendar]).includes(:device).index_by(&:id)
        return [] if points.empty?

        Reading.where(point_id: points.keys, at: f.window).order(at: :desc).limit(f.limit).map do |r|
          p = points[r.point_id]
          v = Logbook.value_of(p, r)
          item(at: r.at, title: Logbook.point_title(p), state: Logbook.text(p, v), tone: v == true ? "success" : "muted", point_id: p.id, ref: { type: "point", id: p.id })
        end
      end
    end

    # Comandos (de pessoas, automações, Alexa, voz) e como terminaram.
    class Commands < Base
      describe key: "commands", label: "Comandos", icon: "lightning-bolt"
      texts "pt-BR" => { via: "pelo %{source}" }, en: { label: "Commands", via: "via %{source}" }, es: { label: "Comandos", via: "por %{source}" }
      TONES = { "confirmed" => "success", "failed" => "danger", "expired" => "warn" }.freeze

      def self.fetch(f)
        scope = Command.where(site_id: f.site.id, created_at: f.window).includes(:user, point: :device).order(created_at: :desc).limit(f.limit)
        scope = scope.where(point_id: f.points.select(:id)) if f.narrowed?
        scope = scope.where(user_id: f.user_id) if f.user_id
        scope.map do |c|
          action = Points::Timeline::COMMAND_LABELS.fetch(c.command, c.command)
          action = "#{action} #{c.value}" if c.value.present? && !c.value.is_a?(Hash)
          item(at: c.created_at, title: Logbook.point_title(c.point), state: action, user: c.user&.name, tone: TONES.fetch(c.status, "muted"),
               detail: [ text(:via, source: c.source_label), c.status_label.downcase, c.error ].compact.join(" · "), point_id: c.point_id,
               ref: { type: "point", id: c.point_id })
        end
      end
    end

    # Execuções de automação e de script (a busca olha o nome delas).
    class Runs < Base
      describe key: "runs", label: "Automações e scripts", icon: "sparkles"
      texts "pt-BR" => { script: "Script", automation: "Automação", shadow: "em sombra" },
            en: { label: "Automations and scripts", script: "Script", automation: "Automation", shadow: "in shadow mode" },
            es: { label: "Automatizaciones y scripts", script: "Script", automation: "Automatización", shadow: "en modo sombra" }

      def self.fetch(f)
        return [] if f.user_id || f.area_id || f.device_id || f.point_id

        scope = AutomationRun.real.where(site_id: f.site.id, started_at: f.window).includes(:automation).order(started_at: :desc).limit(f.limit)
        scope = scope.joins(:automation).where("automations.name ILIKE ?", "%#{ActiveRecord::Base.sanitize_sql_like(f.q)}%") if f.q
        scope.map do |r|
          kind = text(r.automation.kind == "script" ? :script : :automation)
          item(at: r.started_at, title: r.automation.name, state: r.status_label, tone: r.tone == "info" ? "muted" : r.tone,
               detail: [ kind, (text(:shadow) if r.shadow), r.error&.truncate(120) ].compact.join(" · "), ref: { type: "automation_run", id: r.id })
        end
      end
    end

    # Cenas acionadas (evento `scene` gravado pelo `Scene#activate!`).
    class Scenes < Base
      describe key: "scenes", label: "Cenas", icon: "color-swatch"
      texts "pt-BR" => { fired: "Acionada", shadow: "em sombra",
                         source: { web: "pela web", api: "pelo app", automation: "por automação", alexa: "pela Alexa", voice: "por voz" } },
            en: { label: "Scenes", fired: "Activated", shadow: "in shadow mode",
                  source: { web: "on the web", api: "in the app", automation: "by an automation", alexa: "by Alexa", voice: "by voice" } },
            es: { label: "Escenas", fired: "Activada", shadow: "en modo sombra",
                  source: { web: "por la web", api: "por la app", automation: "por una automatización", alexa: "por Alexa", voice: "por voz" } }

      def self.fetch(f)
        return [] if f.area_id || f.device_id || f.point_id

        scope = Event.where(site_id: f.site.id, kind: "scene", at: f.window).order(at: :desc).limit(f.limit)
        scope = scope.where("payload->>'user_id' = ?", f.user_id) if f.user_id
        scope = scope.where("payload->>'name' ILIKE ?", "%#{ActiveRecord::Base.sanitize_sql_like(f.q)}%") if f.q
        events = scope.to_a
        users = User.where(id: events.filter_map { |e| e.payload["user_id"] }).index_by(&:id)
        events.map do |e|
          item(at: e.at, title: e.payload["name"].to_s, state: text(:fired), user: users[e.payload["user_id"]]&.name, tone: "success",
               detail: [ (text("source.#{e.source}") if e.source.present?), (text(:shadow) if e.payload["shadow"]) ].compact.join(" · ").presence, ref: { type: "scene", id: e.payload["scene_id"] })
        end
      end
    end

    # Alertas: abriu, alguém deu ciente, fechou.
    class Alerts < Base
      describe key: "alerts", label: "Alertas", icon: "exclamation-circle"
      texts "pt-BR" => { opened: "Abriu", closed: "Fechou", acked: "Ciente" },
            en: { label: "Alerts", opened: "Opened", closed: "Closed", acked: "Acknowledged" },
            es: { label: "Alertas", opened: "Se abrió", closed: "Se cerró", acked: "Visto" }

      def self.fetch(f)
        base = Alert.where(site_id: f.site.id).includes(:alert_rule, :acked_by, point: :device)
        base = base.where(point_id: f.points.select(:id)) if f.narrowed?
        list = []
        unless f.user_id
          list += base.where(opened_at: f.window).order(opened_at: :desc).limit(f.limit).map { |a| row(a, a.opened_at, text(:opened), "danger") }
          list += base.where(resolved_at: f.window).order(resolved_at: :desc).limit(f.limit).map { |a| row(a, a.resolved_at, text(:closed), "success") }
        end
        acked = base.where(acked_at: f.window)
        acked = acked.where(acked_by_id: f.user_id) if f.user_id
        list + acked.order(acked_at: :desc).limit(f.limit).map { |a| row(a, a.acked_at, text(:acked), "warn", a.acked_by&.name) }
      end

      def self.row(a, at, state, tone, user = nil)
        item(at: at, title: a.alert_rule.name, state: state, tone: tone, user: user, detail: Logbook.point_title(a.point), point_id: a.point_id, ref: { type: "point", id: a.point_id })
      end
    end

    # Ponto que ficou sem sinal, com erro ou voltou.
    class Quality < Base
      describe key: "quality", label: "Conexão", icon: "status-offline"
      texts "pt-BR" => { before: "antes: %{state}" }, en: { label: "Connection", before: "before: %{state}" }, es: { label: "Conexión", before: "antes: %{state}" }

      def self.fetch(f)
        return [] if f.user_id

        scope = Event.where(site_id: f.site.id, kind: "quality", at: f.window).includes(point: :device).order(at: :desc).limit(f.limit)
        scope = scope.where(point_id: f.points.select(:id)) if f.narrowed?
        scope.select(&:point).map do |e|
          to = e.payload["to"]
          item(at: e.at, title: Logbook.point_title(e.point), state: Points::Timeline::QUALITY_LABELS.fetch(to, to), tone: to == "good" ? "success" : "warn",
               detail: text(:before, state: Points::Timeline::QUALITY_LABELS.fetch(e.payload["from"], e.payload["from"]).to_s.downcase), point_id: e.point_id,
               ref: { type: "point", id: e.point_id })
        end
      end
    end

    # Cadastro (criou, mudou, excluiu) do que é do local. Técnico e dono.
    class Audit < Base
      describe key: "audit", label: "Cadastro", icon: "pencil", role: :manage
      TYPES = %w[Point Device Area Automation Scene Dashboard Schedule NotifyRule AlertRule PointLink Integration SiteMembership Blueprint].freeze
      HIDDEN = %w[version draft definition updated_at created_at].freeze
      texts "pt-BR" => { site: "Local",
                         types: { Point: "Ponto", Device: "Dispositivo", Area: "Área", Automation: "Automação", Scene: "Cena", Dashboard: "Painel",
                                  Schedule: "Agenda", NotifyRule: "Aviso", AlertRule: "Regra de alerta", PointLink: "Espelhamento",
                                  Integration: "Integração", SiteMembership: "Acesso", Blueprint: "Blueprint" },
                         actions: { create: "Criado", update: "Alterado", destroy: "Excluído" } },
            en: { label: "Setup", site: "Place",
                  types: { Point: "Point", Device: "Device", Area: "Area", Automation: "Automation", Scene: "Scene", Dashboard: "Dashboard",
                           Schedule: "Schedule", NotifyRule: "Notification", AlertRule: "Alert rule", PointLink: "Mirroring",
                           Integration: "Integration", SiteMembership: "Access", Blueprint: "Blueprint" },
                  actions: { create: "Created", update: "Changed", destroy: "Deleted" } },
            es: { label: "Registro", site: "Lugar",
                  types: { Point: "Punto", Device: "Dispositivo", Area: "Área", Automation: "Automatización", Scene: "Escena", Dashboard: "Panel",
                           Schedule: "Agenda", NotifyRule: "Aviso", AlertRule: "Regla de alerta", PointLink: "Espejado",
                           Integration: "Integración", SiteMembership: "Acceso", Blueprint: "Blueprint" },
                  actions: { create: "Creado", update: "Modificado", destroy: "Eliminado" } }

      def self.fetch(f)
        types = f.narrowed? ? { "Point" => f.points.select(:id) } : TYPES.to_h { |t| [ t, t.constantize.where(site_id: f.site.id).select(:id) ] }
        scope = types.map { |t, ids| AuditEvent.where(auditable_type: t, auditable_id: ids) }.reduce(:or)
        scope = scope.or(AuditEvent.where(auditable_type: "Site", auditable_id: f.site.id)) unless f.narrowed?
        scope = scope.where(tenant_id: f.site.tenant_id, created_at: f.window).where.not(action: "login").order(created_at: :desc).limit(f.limit)
        scope = scope.where(user_id: f.user_id) if f.user_id
        events = scope.to_a
        users = User.where(id: events.filter_map(&:user_id)).index_by(&:id)
        names = events.group_by(&:auditable_type).flat_map do |t, list|
          klass = t.safe_constantize
          klass&.column_names&.include?("name") ? klass.where(id: list.map(&:auditable_id)).pluck(:id, :name) : []
        end.to_h
        events.map do |e|
          kind = TYPES.include?(e.auditable_type) ? text("types.#{e.auditable_type}") : text(:site)
          item(at: e.created_at, title: names[e.auditable_id] || e.details["name"] || kind, state: text("actions.#{e.action}", default: e.action),
               user: users[e.user_id]&.name, detail: [ kind, (e.details.keys - HIDDEN).first(4).map { |k| e.auditable_type.safe_constantize&.human_attribute_name(k)&.downcase || k }.join(", ").presence ].compact.join(" · "),
               point_id: (e.auditable_id if e.auditable_type == "Point"), ref: (e.auditable_type == "Point" && e.action != "destroy" ? { type: "point", id: e.auditable_id } : nil))
        end
      end
    end

    # Entradas na web e no app das pessoas com acesso ao local. Só o dono.
    class Logins < Base
      describe key: "logins", label: "Entradas", icon: "login", role: :admin
      texts "pt-BR" => { entered: "Entrou", via: { web: "na web", app: "no app" } },
            en: { label: "Sign-ins", entered: "Signed in", via: { web: "on the web", app: "in the app" } },
            es: { label: "Ingresos", entered: "Ingresó", via: { web: "en la web", app: "en la app" } }

      def self.fetch(f)
        return [] if f.narrowed?

        users = Logbook.people(f.site)
        users = users.where(id: f.user_id) if f.user_id
        names = users.pluck(:id, :name).to_h
        AuditEvent.where(action: "login", user_id: names.keys, created_at: f.window).order(created_at: :desc).limit(f.limit).map do |e|
          item(at: e.created_at, title: names[e.user_id].to_s, state: text(:entered), detail: (text("via.#{e.details['via']}") if e.details["via"].present?))
        end
      end
    end
  end
end
