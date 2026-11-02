# ondaA2 A20: JS dos cards de terceiros pelo hash (Cards). Público e
# imutável: o iframe sandbox do card tem origem opaca (não manda cookie), e o
# arquivo só existe se um pacote o instalou com o hash conferido.
class CardsController < ActionController::Base
  # Feito para ser embutido por <script> de outra origem (a opaca do iframe).
  skip_forgery_protection

  def show
    body = Cards.read(params[:sha]) or return head(:not_found)

    response.headers["Access-Control-Allow-Origin"] = "*"
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["Cache-Control"] = "public, max-age=31536000, immutable"
    send_data body, type: "text/javascript", disposition: "inline"
  end
end
