# Modo tablet de parede (uiweb): o aparelho guarda num cookie próprio (1 ano)
# que é um quiosque e como é o protetor de tela. `?quiosque=1` liga neste
# aparelho, `?quiosque=0` desliga; os ajustes vêm do formulário do próprio
# quiosque (PATCH /quiosque). Nada no servidor por aparelho.
module KioskMode
  extend ActiveSupport::Concern

  SAVERS = { "clock" => "Relógio", "weather" => "Relógio e clima", "cameras" => "Câmeras", "photos" => "Fotos do painel", "off" => "Nenhum" }.freeze
  DEFAULTS = { "saver" => "clock", "idle" => 2, "motion" => nil, "dim" => true }.freeze
  COOKIE = :ma_kiosk

  included { helper_method :kiosk }

  def kiosk = @kiosk

  private

  # Chamado nas telas de painel: lê o cookie e o `?quiosque=`.
  def load_kiosk
    case params[:quiosque]
    when "1" then write_kiosk(kiosk_cookie)
    when "0" then cookies.delete(COOKIE)
    end
    data = params[:quiosque] == "0" ? nil : (kiosk_cookie if params[:quiosque] == "1" || cookies[COOKIE].present?)
    @kiosk = data && DEFAULTS.merge(data)
  end

  def kiosk_cookie
    JSON.parse(cookies[COOKIE].to_s).slice(*DEFAULTS.keys)
  rescue JSON::ParserError
    {}
  end

  def write_kiosk(data)
    clean = { "saver" => data["saver"].to_s.presence_in(SAVERS.keys) || "clock", "idle" => (data["idle"].to_i.nonzero? || 2).clamp(1, 60),
              "motion" => data["motion"].to_s[/\A[\w-]{1,64}\z/], "dim" => [ true, "1", "true" ].include?(data.fetch("dim", true)) }
    cookies.permanent[COOKIE] = { value: clean.to_json, httponly: true, same_site: :lax }
  end
end
