module Drivers
  # Comandos das câmeras do go2rtc (ondaC2, C10): `ptz` pelo ONVIF da câmera
  # (anda ~1 s e para; ou posição salva "preset:<token>"), `record` (grava
  # N segundos na fila, Recordings) e `play_media` (o go2rtc toca o áudio no
  # alto-falante da câmera: fala, aviso, interfone pelo app). O ao vivo e o
  # quadro seguem pelo Drivers::Go2rtc.
  class Camera
    class Error < StandardError; end

    SPEED = 0.5
    MOVES = { "left" => [ -SPEED, 0, 0 ], "right" => [ SPEED, 0, 0 ], "up" => [ 0, SPEED, 0 ], "down" => [ 0, -SPEED, 0 ],
              "zoom_in" => [ 0, 0, SPEED ], "zoom_out" => [ 0, 0, -SPEED ] }.freeze

    def execute(point, command, value)
      value = Points::Command.new(point, command, value).tap(&:new_value).value
      case command
      when "ptz" then self.class.ptz(point, value)
      when "record" then CameraRecordJob.perform_later(point.id, value, "manual")
      when "play_media" then Go2rtc.play_audio(point, value)
      end
    rescue Onvif::Error, Go2rtc::Error => e
      raise Error, e.message
    end

    class << self
      def poll(_device) = nil

      # [cliente ONVIF, URL do PTZ, perfil] da câmera do ponto.
      def onvif(point)
        d = point.device
        client = Onvif::Client.new(host: d.address["host"], port: d.address["onvif_port"], username: d.address["username"], password: d.credential).sync_clock!
        url = client.services["ptz"] or raise Error, "A câmera não tem PTZ (ONVIF)."
        profile = point.address["profile"].presence || first_profile(client)
        [ client, url, profile ]
      end

      def first_profile(client)
        media = client.services["media"] or raise Error, "A câmera não informou o serviço de vídeo."
        client.profiles(media).first&.dig("token") or raise Error, "A câmera não tem perfil de vídeo."
      end

      def ptz(point, move)
        client, url, profile = onvif(point)
        if move == "home" then client.ptz_home(url, profile)
        elsif move.start_with?("preset:") then client.ptz_preset(url, profile, move.delete_prefix("preset:"))
        else
          pan, tilt, zoom = MOVES.fetch(move)
          client.ptz_move(url, profile, pan: pan, tilt: tilt, zoom: zoom, seconds: 1)
        end
      end

      def presets(point)
        client, url, profile = onvif(point)
        client.ptz_presets(url, profile)
      rescue Onvif::Error, Error
        []
      end
    end
  end
end
