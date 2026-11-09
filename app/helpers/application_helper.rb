module ApplicationHelper
  include Pagy::Frontend

  # Quando, curto (lista no celular): até 7 dias "há 3 h"; depois a data ("08/11/2026").
  # Vai num <time> com a data e hora completas no title.
  def ma_when(time)
    text = time > 7.days.ago ? t("dashboards.w.ago", time: dw_short_ago(time)) : l(time.to_date)
    tag.time(text, datetime: time.iso8601, title: l(time, format: :long))
  end

  NOTIFICATION_KINDS = { "convite" => [ "users", "is-accent" ],
                         "resumo_diario" => [ "calendar", "is-accent" ],
                         "aviso" => [ "bell", "is-accent" ],
                         "alerta" => [ "exclamation-circle", "is-danger" ],
                         "automacao" => [ "lightning-bolt", "is-accent" ] }.freeze

  # catalogo: formulário da integração: a partial própria do plugin ou a gerada dos campos (SchemaPlugin).
  def integration_form_partial(plugin)
    own = "web/integrations/forms/#{plugin.key}"
    lookup_context.exists?(own, [], true) || !plugin.respond_to?(:fields) ? own : "web/integrations/forms/schema"
  end

  # Passo de login: a partial própria, a genérica do OAuth (OauthPlugin) ou nenhuma.
  def integration_connect_partial(plugin)
    own = "web/integrations/connect/#{plugin.key}"
    return own if lookup_context.exists?(own, [], true)

    "web/integrations/connect/oauth" if plugin.respond_to?(:oauth_config)
  end

  def initials(name) = name.to_s.split.first(2).map { |w| w[0] }.join.upcase

  # Valor em <span class="money"> para o "esconder valores" borrar. Dentro de string ou atributo, use Money.format.
  def money(cents) = tag.span(Money.format(cents), class: "money")

  # Texto pronto do servidor ("Fiado vencido: R$ 92,87") com os valores em .money.
  def with_money(text)
    safe_join(text.to_s.split(/(-?R\$\s?[\d.]+,\d{2})/).map.with_index { |part, i| i.odd? ? tag.span(part, class: "money") : part })
  end

  # Só dígitos no banco → "123.456.789-01", "12.345.678/0001-95", "(61) 98888-7777".
  def document_text(d)
    case d.to_s
    when /\A(\d{3})(\d{3})(\d{3})(\d{2})\z/ then "#{$1}.#{$2}.#{$3}-#{$4}"
    when /\A(\d{2})(\d{3})(\d{3})(\d{4})(\d{2})\z/ then "#{$1}.#{$2}.#{$3}/#{$4}-#{$5}"
    else d
    end
  end

  def phone_text(p) = p.to_s.sub(/\A(\d{2})(\d{4,5})(\d{4})\z/, '(\1) \2-\3').presence

  def greeting = t(%w[greeting.morning greeting.afternoon greeting.evening][Time.current.hour < 12 ? 0 : Time.current.hour < 18 ? 1 : 2])

  # Menu do Ss::AppShellComponent (nav:): os itens da pessoa (sidebar_entries) num grupo
  # sem título e, depois de um separador, Configurações. Selo 0 a gem esconde.
  def shell_nav
    items = sidebar_entries.map do |e|
      n = e[:badge]&.call.to_i
      { key: e[:key], label: e[:label], href: e[:path], icon: icon(e[:icon], ""), current: nav_current?(e[:path]),
        badge: (n > 99 ? "99+" : n) }
    end
    fixed, main = items.partition { |i| SIDEBAR_FIXED.include?(i[:key]) }
    [ { items: main }, ({ separator: true } if fixed.any?), ({ items: fixed } if fixed.any?) ].compact
  end

  # Troca de local do Ss::AppShellComponent (tenants:): só nas telas que mostram um
  # local por vez (Diário, Histórico, Mapa), que a pedem pela web/shared/site_switch.
  def shell_tenants(sites, site, path)
    return [] if sites.size < 2

    sites.map { |s| { name: s.name, href: "#{path}?site_id=#{s.id}", current: s.id == site.id } }
  end

  # ondaB2 (B11): itens do menu lateral, com a ordem e o que a pessoa
  # escondeu (`dashboard_prefs["sidebar"]`). Configurações fica sempre.
  # `all: true` devolve também os escondidos (marcados), para a tela Aparência.
  SIDEBAR_FIXED = %w[settings].freeze

  def sidebar_entries(all: false)
    user = current_user
    reader = user.reader?
    # O Início é o painel padrão do local: leva o nome e o ícone dele e o painel
    # não se repete na lista (antes: "Início" + "Casa" levando à mesma tela).
    home = Dashboard.where(site_id: Site.visible_to(user).select(:id), site_default: true).ordered.includes(:site).to_a
                    .find { |d| d.visible_to?(d.site.role_for(user)) }
    list = [ { key: "home", label: home&.name || t("nav.home"), path: root_path, icon: home&.icon_name || "lightning-bolt" } ]
    list += Dashboard.sidebar_for(user).reject { |d| d.id == home&.id }.map { |d| { key: "dash:#{d.id}", label: d.name, path: dashboard_path(d), icon: d.icon_name } }
    list += Cards.panels(Site.visible_to(user)).map { |p| { key: "panel:#{p['package'].id}:#{p['key']}", label: p["name"], path: custom_panel_path(p["package"], p["key"]), icon: p["icon"] } } # resto
    unless reader
      list += [ { key: "logbook", label: t("nav.logbook"), path: logbook_path, icon: "view-list" },
                { key: "history", label: t("nav.history"), path: history_path, icon: "chart-bar" },
                ({ key: "map", label: t("nav.map"), path: map_path, icon: "map" } if Maps.allowed?(user)),
                { key: "alerts", label: t("nav.alerts"), path: alerts_path, icon: "exclamation-circle",
                  badge: -> { Alert.active.where(acked_at: nil, site_id: Site.visible_to(user).select(:id)).count } },
                { key: "ask", label: t("nav.ask"), path: ask_path, icon: "sparkles" } ].compact
    end
    list << { key: "notifications", label: t("nav.notifications"), path: notifications_path, icon: "bell", badge: -> { Notification.for_user(user).unread.count } }
    list << { key: "settings", label: reader ? t("nav.account") : t("nav.settings"), path: reader ? settings_account_path : settings_path, icon: "cog" }
    prefs = user.dashboard_prefs.to_h["sidebar"].to_h
    order = Array(prefs["order"])
    hidden = Array(prefs["hidden"]) - SIDEBAR_FIXED
    list = list.sort_by.with_index { |e, i| [ e[:key] == "settings" ? 1 : 0, order.index(e[:key]) || (order.size + i) ] }
    list.each { |e| e[:hidden] = hidden.include?(e[:key]) }
    all ? list : list.reject { |e| e[:hidden] }
  end

  # Item ativo: a própria página ou uma página abaixo dela.
  def nav_current?(path)
    return current_page?(path) if path == root_path

    request.path == path || request.path.start_with?("#{path}/")
  end

  def date(value) = value && l(value.to_date, format: :default)

  # Botão do Google: só com client configurado e num endereço que o Google aceita.
  def google_login_available? = GoogleLogin.enabled? && GoogleLogin.usable_host?(request.host)

  # Ícone de traço (Heroicons v1 outline, MIT — os mesmos do meu-financeiro),
  # inlinado para herdar a cor do texto. Arquivos em app/assets/images/icons.
  # Também aceita os ícones do Home Assistant (`mdi:nome`, Mdi). Nome que não
  # existe cai no FALLBACK (o painel importado nunca quebra por um ícone).
  ICON_NAME = /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/
  ICON_FALLBACK = "view-grid".freeze
  ICONS = Hash.new do |h, name|
    file = Rails.root.join("app/assets/images/icons/#{name}.svg") if name.match?(ICON_NAME)
    file = Rails.root.join("app/assets/images/icons/#{ICON_FALLBACK}.svg") unless file&.exist?
    h[name] = file.read
                   .sub("<svg ", %(<svg aria-hidden="true" focusable="false" )).gsub('stroke-width="2"', 'stroke-width="1.75"').strip
  end

  # Devolve o <svg> como String html_safe: serve direto nos parâmetros de SVG cru dos
  # componentes da gem componentes_ui (icon:, nav:, items com :icon...), que fazem
  # `.to_s.html_safe` e dimensionam o svg pelo próprio CSS. Para o tamanho ficar com o
  # componente, passe css vazio: `render Ss::CollapsibleComponent.new(title: "Sala", icon: icon("home", ""))`.
  def icon(name, css = "size-5")
    name = name.to_s
    return (Mdi.svg(name, css) || icon(ICON_FALLBACK, css)).html_safe if Mdi.name?(name) # rubocop:disable Rails/OutputSafety

    ICONS[name].sub("<svg ", %(<svg data-icon="#{ERB::Util.html_escape(name)}" class="#{css}" )).html_safe # rubocop:disable Rails/OutputSafety
  end
end
