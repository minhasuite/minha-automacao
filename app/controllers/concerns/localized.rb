# Idioma da tela (produto): o escolhido pela pessoa (`users.dashboard_prefs
# ["locale"]`), senão o do cookie (escolhido na tela de entrar ou na primeira
# configuração), senão o melhor do navegador (Accept-Language), senão pt-BR.
module Localized
  extend ActiveSupport::Concern

  COOKIE = :ma_locale
  NAMES = { "pt-BR" => "Português", "en" => "English", "es" => "Español" }.freeze

  included { around_action :switch_locale }

  # "en-US,en;q=0.9,pt;q=0.8" → o primeiro disponível (idioma exato, depois só a língua).
  def self.from_header(header)
    available = I18n.available_locales.map(&:to_s)
    tags = header.to_s.split(",").map { |p| p.split(";").first.to_s.strip }.compact_blank
    tags.each do |tag|
      exact = available.find { |l| l.casecmp?(tag) }
      return exact if exact

      lang = available.find { |l| l.split("-").first.casecmp?(tag.split("-").first) }
      return lang if lang
    end
    nil
  end

  def self.valid(locale) = locale.to_s.presence_in(I18n.available_locales.map(&:to_s))

  private

  def switch_locale(&)
    I18n.with_locale(pick_locale, &)
  end

  def pick_locale
    Localized.valid(current_user&.dashboard_prefs&.dig("locale")) || Localized.valid(cookies[COOKIE]) ||
      Localized.from_header(request.headers["Accept-Language"]) || I18n.default_locale
  end
end
