# Drivers que executam comando (ESQUEMA-V1 §4.2). Interface mínima:
# `execute(point, command, value)` aplica no aparelho e reporta o valor novo
# com `point.report!`; erro levanta exceção (o comando vira `failed`).
module Drivers
  REGISTRY = { "virtual" => "Drivers::Virtual", "tuya_local" => "Drivers::TuyaLocal", "mqtt" => "Drivers::Mqtt",
               "xiaomi_miot" => "Drivers::XiaomiMiot", "alexa" => "Drivers::Alexa" }.freeze

  def self.supported?(device) = REGISTRY.key?(device.driver)
  def self.for(device) = REGISTRY.fetch(device.driver).constantize.new
end
