module Integrations
  # UniFi Protect (integ): câmeras do console UniFi pela API local do
  # Protect, com a detecção inteligente virando detecção genérica. Lógica em
  # ::UnifiProtect.
  class UnifiProtectPlugin < LanPlugin
    describe key: "unifi_protect", title: "UniFi Protect", icon: "video-camera",
             description: "Câmeras do UniFi Protect (UDM, UNVR, Cloud Key): movimento e detecção de pessoa, veículo, animal e encomenda, com o quadro no aviso."
    texts en: { title: "UniFi Protect", description: "UniFi Protect cameras (UDM, UNVR, Cloud Key): motion and person, vehicle, animal and package detection, with a snapshot in the alert." },
          es: { title: "UniFi Protect", description: "Cámaras de UniFi Protect (UDM, UNVR, Cloud Key): movimiento y detección de personas, vehículos, animales y paquetes, con la imagen en el aviso." }
    port 443
    plain :username
    secrets :password

    def self.inventory(integration) = UnifiProtect.inventory(integration)
    def self.snapshot(point) = UnifiProtect.snapshot(point)
  end
end
