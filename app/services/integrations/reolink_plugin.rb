module Integrations
  # Reolink (integ): câmera ou NVR da rede pela API do aparelho, com a
  # detecção nativa (pessoa, veículo, animal) virando detecção genérica.
  # Lógica em ::Reolink.
  class ReolinkPlugin < LanPlugin
    describe key: "reolink", title: "Reolink", icon: "video-camera",
             description: "Câmeras e NVR Reolink da rede: movimento e detecção de pessoa, veículo e animal do próprio aparelho, com o quadro no aviso."
    port 80
    plain :username
    secrets :password

    def self.inventory(integration) = Reolink.inventory(integration)
    def self.snapshot(point) = Reolink.snapshot(point)
  end
end
