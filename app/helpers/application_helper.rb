module ApplicationHelper
  include Pagy::Frontend

  NOTIFICATION_KINDS = { "convite" => [ "users", "bg-accent-soft text-accent" ],
                         "resumo_diario" => [ "calendar", "bg-accent-soft text-accent" ],
                         "aviso" => [ "bell", "bg-accent-soft text-accent" ],
                         "alerta" => [ "exclamation-circle", "bg-danger-soft text-danger" ],
                         "automacao" => [ "lightning-bolt", "bg-accent-soft text-accent" ] }.freeze

  # catalogo: formulário da integração: a partial própria do plugin ou a gerada dos campos (SchemaPlugin).
  def integration_form_partial(plugin)
    own = "web/integrations/forms/#{plugin.key}"
    lookup_context.exists?(own, [], true) || !plugin.respond_to?(:fields) ? own : "web/integrations/forms/schema"
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

  def nav_link(label, path, icon: nil, badge: nil, **opts)
    link_to path, "aria-current": (nav_current?(path) ? "page" : nil), title: label, **opts do
      safe_join([ (icon(icon, "") if icon), tag.span(label, class: "ss-side-label truncate flex-1"),
                  (tag.span(badge > 99 ? "99+" : badge, class: "ss-nav-badge", "aria-label": t("nav.unread", count: badge)) if badge.to_i.positive?) ].compact)
    end
  end

  # ondaB2 (B11): itens do menu lateral, com a ordem e o que a pessoa
  # escondeu (`dashboard_prefs["sidebar"]`). Configurações fica sempre.
  # `all: true` devolve também os escondidos (marcados), para a tela Aparência.
  SIDEBAR_FIXED = %w[settings].freeze

  def sidebar_entries(all: false)
    user = current_user
    reader = user.reader?
    list = [ { key: "home", label: t("nav.home"), path: root_path, icon: "lightning-bolt" } ]
    list += Dashboard.sidebar_for(user).map { |d| { key: "dash:#{d.id}", label: d.name, path: dashboard_path(d), icon: d.icon_name } }
    unless reader
      list += [ { key: "sites", label: t("nav.sites"), path: sites_path, icon: "home" },
                { key: "logbook", label: t("nav.logbook"), path: logbook_path, icon: "view-list" },
                { key: "history", label: t("nav.history"), path: history_path, icon: "chart-bar" },
                ({ key: "map", label: t("nav.map"), path: map_path, icon: "map" } if Maps.allowed?(user)),
                { key: "alerts", label: t("nav.alerts"), path: alerts_path, icon: "exclamation-circle",
                  badge: -> { Alert.active.where(acked_at: nil, site_id: Site.visible_to(user).select(:id)).count } },
                { key: "ask", label: t("nav.ask"), path: ask_path, icon: "sparkles" } ].compact
    end
    list << { key: "notifications", label: t("nav.notifications"), path: notifications_path, icon: "bell", badge: -> { Notification.for_user(user).unread.count } }
    list << { key: "settings", label: reader ? t("nav.account") : t("nav.settings"), path: reader ? settings_account_path : settings_path, icon: "cog", class: "mt-3" }
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

  # Ícone de traço (Heroicons v1 outline, MIT — os mesmos do meu-financeiro),
  # inlinado para herdar a cor do texto. Arquivos em app/assets/images/icons.
  ICONS = Hash.new do |h, name|
    h[name] = Rails.root.join("app/assets/images/icons/#{name}.svg").read
                   .sub("<svg ", %(<svg aria-hidden="true" focusable="false" )).gsub('stroke-width="2"', 'stroke-width="1.75"').strip
  end

  def icon(name, css = "size-5")
    ICONS[name.to_s].sub("<svg ", %(<svg data-icon="#{name}" class="#{css}" )).html_safe # rubocop:disable Rails/OutputSafety
  end
end
