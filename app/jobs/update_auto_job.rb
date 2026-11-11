# Distribuição: avisa o fim da última atualização e, com "atualizar sozinho"
# ligado, atualiza na janela de horário (Updates::Auto).
class UpdateAutoJob < ApplicationJob
  include SlowJob

  def perform = Updates::Auto.tick!
end
