# Tela de Câmeras (cameras2): quais pontos são câmera que a tela toca. A mesma regra do
# proxy (`Web::CamerasController#load_camera`) e da API (`Api::V1::CamerasController`).
module Cameras
  class Error < StandardError; end

  module_function

  # Ponto de vídeo que passa pelo go2rtc (ou o quadro do MQTT, ou a câmera de nuvem).
  def camera?(point)
    point.capability == "stream" && (point.device.driver == "go2rtc" || point.address["image"] == "mqtt" || point.address["on_demand"].present?)
  end

  # Câmeras do local, na ordem da tela (área, nome); só as ligadas.
  def for_site(site)
    site.points.where(capability: "stream", disabled: false).includes(:device, :area)
        .select { |p| camera?(p) && !p.device.disabled }
        .sort_by { |p| [ p.area&.name.to_s, p.name.to_s ] }
  end

  # O que a tela sabe fazer com a câmera (o app desenha só o que veio).
  def features(point)
    # Sem `writable` a câmera não aceita comando (falar e mover ficam escondidos).
    cmds = point.writable ? Points::Command.commands_for(point) : []
    { "live" => point.device.driver == "go2rtc" || point.address["on_demand"].present?,
      "talk" => cmds.include?("play_media"), "ptz" => cmds.include?("ptz"),
      "playback" => Playback.available?(point) }
  end
end
