# SSML (`<speak>…</speak>`, o formato das falas da Alexa que vieram do HA).
# Canal de fala usa o SSML; tela, push e mensageiro recebem o texto puro.
module Ssml
  module_function

  def ssml?(text) = text.to_s.lstrip.start_with?("<speak")

  # "<speak><prosody volume=\"soft\">Portão fechado.</prosody></speak>" → "Portão fechado."
  def plain(text)
    return text unless ssml?(text)

    CGI.unescapeHTML(text.to_s.gsub(/<break[^>]*>/i, " ").gsub(/<[^>]+>/, "")).squish
  end
end
