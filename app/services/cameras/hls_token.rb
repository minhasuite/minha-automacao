# Link do HLS da câmera (cameras2): o player (app, Safari antigo) pede o índice e os
# pedaços sem sessão nem cabeçalho, então o link leva um token assinado com o ponto, a
# pessoa e o stream (o ponto ou uma reprodução). Vai no caminho (os endereços relativos
# do go2rtc continuam embaixo dele). Vale TTL; a pessoa e o papel são conferidos de novo.
module Cameras
  module HlsToken
    TTL = 6.hours

    module_function

    def verifier
      @verifier ||= ActiveSupport::MessageVerifier.new(Rails.application.key_generator.generate_key("cameras-hls", 32),
                                                       digest: "SHA256", serializer: JSON, url_safe: true)
    end

    def generate(point, user, src) = verifier.generate({ "p" => point.id, "u" => user.id, "s" => src.to_s }, expires_in: TTL, purpose: :camera_hls)

    def verify(token) = verifier.verified(token.to_s, purpose: :camera_hls)
  end
end
