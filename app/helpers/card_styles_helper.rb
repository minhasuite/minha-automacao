# Ideia 19: o estilo dos cards do painel (Dashboards::CardStyles) nos atributos
# do <body>, junto do tema: os tokens do componentes-ui que o estilo troca.
module CardStylesHelper
  def dw_card_style_attrs(body, key)
    css = Dashboards::CardStyles.css(key)
    return body if css.blank?

    body = (body || {}).dup
    body["style"] = [ body["style"].presence, css ].compact.join("; ")
    body["class"] = [ body["class"].presence, "dw-card-style-#{key}" ].compact.join(" ")
    body
  end
end
