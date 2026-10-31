# Drivers que executam comando (ESQUEMA-V1 §4.2). Interface mínima:
# `execute(point, command, value)` aplica no aparelho e reporta o valor novo
# com `point.report!`; erro levanta exceção (o comando vira `failed`).
module Drivers
  REGISTRY = { "virtual" => "Drivers::Virtual", "tuya_local" => "Drivers::TuyaLocal", "tuya_cloud" => "Drivers::TuyaCloud", "mqtt" => "Drivers::Mqtt",
               "xiaomi_miot" => "Drivers::XiaomiMiot", "alexa" => "Drivers::Alexa",
               # Pacote 1: aparelhos da rede, mídia, Matter, IR/RF e Spotify.
               "esphome" => "Drivers::Esphome", "shelly" => "Drivers::Shelly", "matter" => "Drivers::Matter", "broadlink" => "Drivers::Broadlink",
               "cast" => "Drivers::Cast", "webos" => "Drivers::Webos", "tizen" => "Drivers::Tizen", "adb" => "Drivers::Adb", "spotify" => "Drivers::Spotify" }.freeze

  def self.supported?(device) = REGISTRY.key?(device.driver)
  def self.for(device) = REGISTRY.fetch(device.driver).constantize.new
end
