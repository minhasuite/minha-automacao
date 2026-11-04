# Distribuição: avisa o fim da última atualização e, com "atualizar sozinho"
# ligado, atualiza na janela de horário (Updates::Auto).
class UpdateAutoJob < ApplicationJob
  queue_as :default

  def perform = Updates::Auto.tick!
end
