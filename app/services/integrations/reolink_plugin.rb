module Integrations
  # Reolink (integ): câmera ou NVR da rede pela API do aparelho, com a
  # detecção nativa (pessoa, veículo, animal) virando detecção genérica.
  # Lógica em ::Reolink.
  class ReolinkPlugin < LanPlugin
    describe key: "reolink", title: "Reolink", icon: "video-camera",
             description: "Câmeras e NVR Reolink da rede: movimento e detecção de pessoa, veículo e animal do próprio aparelho, com o quadro no aviso."
    texts en: { title: "Reolink", description: "Reolink cameras and NVRs on your network: motion and person, vehicle and animal detection from the device itself, with a snapshot in the alert." },
          es: { title: "Reolink", description: "Cámaras y NVR Reolink de la red: movimiento y detección de personas, vehículos y animales del propio aparato, con la imagen en el aviso." }
    port 80
    plain :username
    secrets :password

    def self.inventory(integration) = Reolink.inventory(integration)
    def self.snapshot(point) = Reolink.snapshot(point)
  end
end
