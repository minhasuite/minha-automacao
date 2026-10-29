module ApplicationHelper
  include Pagy::Frontend

  NOTIFICATION_KINDS = { "convite" => [ "users", "bg-accent-soft text-accent" ],
                         "resumo_diario" => [ "calendar", "bg-accent-soft text-accent" ],
                         "aviso" => [ "bell", "bg-accent-soft text-accent" ],
                         "alerta" => [ "exclamation-circle", "bg-danger-soft text-danger" ],
                         "automacao" => [ "lightning-bolt", "bg-accent-soft text-accent" ] }.freeze

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

  def greeting = [ "Bom dia", "Boa tarde", "Boa noite" ][Time.current.hour < 12 ? 0 : Time.current.hour < 18 ? 1 : 2]

  def nav_link(label, path, icon: nil, badge: nil, **opts)
    link_to path, "aria-current": (nav_current?(path) ? "page" : nil), title: label, **opts do
      safe_join([ (icon(icon, "") if icon), tag.span(label, class: "ss-side-label truncate flex-1"),
                  (tag.span(badge > 99 ? "99+" : badge, class: "ss-nav-badge", "aria-label": "#{badge} não lidas") if badge.to_i.positive?) ].compact)
    end
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
    ICONS[name.to_s].sub("<svg ", %(<svg class="#{css}" )).html_safe # rubocop:disable Rails/OutputSafety
  end
end
