# Ícones Material Design (MDI, os do Home Assistant: `mdi:stove`), Apache 2.0,
# de vendor/mdi/mdi.json ({nome => path do SVG 24x24}). Carrega uma vez, na
# primeira vez que alguém pede. Nome fora do padrão ou que não existe = nil
# (quem chama cai no ícone padrão).
module Mdi
  PREFIX = "mdi:".freeze
  NAME = /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/
  FILE = Rails.root.join("vendor/mdi/mdi.json")

  module_function

  def name?(icon) = icon.to_s.start_with?(PREFIX)
  def paths = @paths ||= JSON.parse(FILE.read)

  def path(icon)
    name = icon.to_s.delete_prefix(PREFIX)
    name.match?(NAME) ? paths[name] : nil
  end

  def svg(icon, css)
    d = path(icon) or return nil
    %(<svg data-icon="#{ERB::Util.html_escape(icon)}" class="#{ERB::Util.html_escape(css)}" aria-hidden="true" focusable="false" viewBox="0 0 24 24" fill="currentColor"><path d="#{d}"/></svg>)
  end
end
