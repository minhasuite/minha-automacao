module Integrations
  # Painéis do Home Assistant → painéis daqui (parte do "Migre do HA"). Lê pelo
  # WebSocket da integração `home_assistant` (só leitura): a lista de painéis
  # (`get_panels`), a configuração já resolvida de cada um (`lovelace/config`)
  # e os temas; as imagens de fundo e de card (`/local/...`) vêm pelo HTTP e
  # ficam anexadas ao painel. A tradução é do Dashboards::HaImport.
  #
  # Idempotente: o par painel do HA ↔ painel daqui fica no ExternalRef
  # (`dashboard:<url_path>`); importar de novo publica uma versão nova do
  # mesmo painel. Painel com "mobile" no caminho vira o padrão do app; o
  # principal (Casa, Início) vira o padrão da web.
  module HaDashboards
    SOURCE = HomeAssistantImport::SOURCE
    KIND = "dashboard".freeze
    MAX_IMAGE = 8.megabytes
    IMAGE_TYPES = %w[image/jpeg image/png image/webp image/gif].freeze
    MAIN = /\A(casa|home|inicio|lovelace)/
    Report = Data.define(:dashboards, :notes)

    module_function

    def transport_for(integration) = HaMigration::Transport.new(integration)

    # → [{"url_path", "title", "icon", "sidebar", "admin", "config"}], na ordem do HA.
    def fetch(integration, transport: transport_for(integration))
      panels = transport.ws("get_panels").to_h.values.select { |p| p["component_name"] == "lovelace" }
      panels.filter_map do |p|
        path = p["url_path"].to_s
        config = begin
          transport.ws("lovelace/config", **(path == "lovelace" ? {} : { url_path: path }))
        rescue Integrations::Error
          nil # o painel padrão sem configuração ("No config found")
        end
        next unless config.is_a?(Hash) && Array(config["views"]).any?

        { "url_path" => path, "title" => p["title"].presence || config["title"].presence || path.humanize,
          "icon" => p["icon"], "sidebar" => p["title"].present?, "admin" => p["require_admin"] == true, "config" => config }
      end
    end

    # Importa (ou reimporta) os painéis; `only` = url_paths escolhidos. → Report.
    def call(site, integration, only: nil, transport: transport_for(integration), images: method(:download))
      panels = fetch(integration, transport: transport)
      panels.select! { |p| Array(only).map(&:to_s).include?(p["url_path"]) } if only
      notes = []
      dashboards = ensure_dashboards(site, panels)
      refs = refs_for(site, dashboards)
      theme = theme_key(site, integration, transport, panels)
      done = panels.map do |p|
        d = dashboards.fetch(p["url_path"])
        cache = {}
        image = ->(url) { cache.fetch(url) { cache[url] = attach(d, integration, url, images, notes) } }
        result = Dashboards::HaImport.new(p["config"], refs: refs, url_path: p["url_path"], image: image, theme: theme).call
        publish(d, result.definition, notes, p["title"])
        notes.concat(result.notes.map { |n| "#{p['title']} › #{n}" })
        d
      end
      mark_defaults(site, panels, dashboards)
      Report.new(dashboards: done, notes: notes)
    end

    # Painel daqui para cada um do HA (cria os que faltam, pelo de-para).
    def ensure_dashboards(site, panels)
      linked = ExternalRef.map_for(site, SOURCE, "Dashboard")
      panels.each_with_index.to_h do |p, i|
        ext = "#{KIND}:#{p['url_path']}"
        d = site.dashboards.find_by(id: linked[ext]) ||
            site.dashboards.create!(name: p["title"].to_s.first(60), kind: "custom", auto: false, position: 100 + i,
                                    definition: placeholder(p["title"]))
        d.update!(name: p["title"].to_s.first(60), icon: (p["icon"] if p["icon"].present? && Mdi.path(p["icon"])),
                  sidebar: p["sidebar"], roles: p["admin"] ? %w[technician owner] : [])
        ExternalRef.link!(site, SOURCE, ext, kind: KIND, target: d, name: p["title"])
        [ p["url_path"], d ]
      end
    end

    def placeholder(title) = { "schema_version" => Dashboards::Schema::VERSION,
                               "views" => [ { "id" => "v-home", "title" => title.to_s.presence || "Início", "sections" => [] } ] }

    # De-para da migração: entidade → ponto (scripts pelo ponto do script), cena, área e os painéis.
    def refs_for(site, dashboards)
      entity = ExternalRef.map_for(site, SOURCE, "Point")
      ExternalRef.map_for(site, SOURCE, "Automation").each do |ext, id|
        script = site.scripts.find_by(id: id) or next
        p = Scripts.point_for(script) and entity[ext] = p.id
      end
      areas = ExternalRef.map_for(site, SOURCE, "Area").to_h { |ext, id| [ ext.delete_prefix("area:"), id ] }
      { "entity" => entity, "scene" => ExternalRef.map_for(site, SOURCE, "Scene"), "area" => areas,
        "dashboard" => dashboards.transform_values(&:id), "jinja" => Automations::HaTemplates.translator(site) }
    end

    # Tema do HA usado nas visões → tema criado daqui (cores do tema, vidro).
    def theme_key(site, integration, transport, panels)
      name = panels.flat_map { |p| Array(p.dig("config", "views")).map { |v| v["theme"] } }.compact.tally.max_by(&:last)&.first
      return nil if name.blank?

      vars = transport.ws("frontend/get_themes").to_h.dig("themes", name).to_h
      vars = vars["modes"].to_h["dark"].to_h.merge(vars.except("modes")) if vars["modes"].is_a?(Hash)
      color = ->(*keys) { keys.filter_map { |k| vars[k].to_s[/#\h{6}\b/] }.first }
      ref = "theme:#{name}"
      existing = ExternalRef.map_for(site, SOURCE, "DashboardTheme")[ref]
      theme = DashboardTheme.find_by(id: existing) || DashboardTheme.new
      theme.update!(name: name.to_s.humanize.first(40), accent: color.("primary-color", "accent-color") || "#7c3aed",
                    accent2: color.("accent-color", "primary-color") || "#0ea5e9", glass: true)
      ExternalRef.link!(site, SOURCE, ref, kind: "theme", target: theme, name: name)
      theme.key
    rescue Integrations::Error, ActiveRecord::RecordInvalid
      nil
    end

    # Imagem do HA (`/local/...`) → anexo do painel → caminho daqui. nil = não veio.
    def attach(dashboard, integration, url, images, notes)
      return url if url.to_s.start_with?("https://")

      path = url.to_s.start_with?("/") ? url.to_s : "/#{url}"
      return nil unless path.start_with?("/local/", "/api/image/", "/media/local/")

      body, type = images.call(integration, path)
      return (notes << "imagem #{path} não veio" && nil) unless body && IMAGE_TYPES.include?(type) && body.bytesize <= MAX_IMAGE

      blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(body), filename: File.basename(path.split("?").first), content_type: type)
      dashboard.files.attach(blob)
      Rails.application.routes.url_helpers.rails_blob_path(blob, only_path: true)
    end

    def download(integration, path)
      res = SafeHttp.get("#{integration.settings['url']}#{path}", headers: { "Authorization" => "Bearer #{integration.secrets['token']}" }, timeout: 30)
      res.status == 200 ? [ res.body.to_s.b, res.headers["content-type"].to_s.split(";").first ] : nil
    rescue SafeHttp::Error, SafeHttp::Blocked
      nil
    end

    # Publica a versão nova; definição recusada pelo Schema vira nota (o painel fica como estava).
    def publish(dashboard, definition, notes, title)
      errors = Dashboards::Schema.errors(definition)
      return notes.concat(errors.first(10).map { |e| "#{title}: não publicado: #{e}" }) if errors.any?

      dashboard.publish!(definition)
    end

    # Padrão da web: o principal (Casa/Início) sem "mobile"; do app: o primeiro com "mobile".
    def mark_defaults(site, panels, dashboards)
      desktop = panels.reject { |p| p["url_path"].include?("mobile") }
      mobile = panels.select { |p| p["url_path"].include?("mobile") }
      main = desktop.find { |p| p["url_path"].match?(MAIN) } || desktop.first
      app = mobile.find { |p| p["url_path"].match?(MAIN) || p["url_path"] == "mobile-home" } || mobile.first
      if main
        site.dashboards.update_all(site_default: false)
        dashboards[main["url_path"]].update!(site_default: true)
      end
      return unless app

      site.dashboards.update_all(app_default: false)
      dashboards[app["url_path"]].update!(app_default: true)
    end
  end
end
