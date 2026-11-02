# Dados sensíveis (IP, usuário e endereço de câmera, tokens, MAC) só para quem
# cadastra (técnico ou dono no local). Os outros papéis recebem o valor
# trocado por "oculto", na web e na API. Chave nova = entrada em `KEYS`;
# formato novo de valor = entrada em `PATTERNS`.
module Sensitive
  MASK = "oculto".freeze
  KEYS = %w[host hostname ip ip_address mac mac_address bssid user username login url stream_url rtsp token access_token
            refresh_token api_key local_key password secret cookie cookies serial].freeze
  PATTERNS = [
    /\b(?:\d{1,3}\.){3}\d{1,3}(?::\d+)?\b/, # IPv4[:porta]
    /\b\h{2}(?:[:-]\h{2}){5}\b/, # MAC
    %r{\b[a-z][a-z0-9+.-]*://\S+}i # URL (rtsp://usuario:senha@...)
  ].freeze

  module_function

  def reveal?(role) = SiteMembership.allowed?(role, :manage)

  # Hash/array (endereço, atributos): troca o valor das chaves sensíveis e o texto que pareça IP, MAC ou URL.
  def mask(value)
    case value
    when Hash then value.to_h { |k, v| [ k, KEYS.include?(k.to_s.downcase) && !v.nil? ? MASK : mask(v) ] }
    when Array then value.map { |v| mask(v) }
    when String then scrub(value)
    else value
    end
  end

  def scrub(text) = PATTERNS.reduce(text.to_s) { |t, re| t.gsub(re, MASK) }
end
