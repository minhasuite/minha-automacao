# ondaA2 A18: confere todo dia a versão de firmware dos aparelhos que se atualizam (Firmware).
class FirmwareCheckJob < ApplicationJob
  include SlowJob

  def perform = Firmware.check_all!
end
