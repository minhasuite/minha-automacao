# Controle remoto genérico (Pacote 1): ponto de capacidade `remote` com os
# códigos aprendidos em `address.codes` ({nome do botão → código}). O
# transporte (Broadlink, IR da Tuya, qualquer outro) só sabe mandar e aprender
# um código; guardar, apagar e virar botão/comando é daqui. Transporte novo =
# driver com `send_code(point, code)` e `learn(point)` (devolve o código ou
# levanta erro) que chama `Remotes.execute(self, point, command, value)`.
module Remotes
  class Error < StandardError; end

  module_function

  def execute(transport, point, command, name)
    case command # comandos da capacidade, não tipos de aparelho
    when "send" then transport.send_code(point, point.address.dig("codes", name))
    when "learn" then store!(point, name, transport.learn(point) || raise(Error, "Nenhum código recebido. Aponte o controle e tente de novo."))
    when "forget" then store!(point, name, nil)
    end
    point.report!(value(point, name))
  end

  def store!(point, name, code)
    codes = (point.address["codes"].is_a?(Hash) ? point.address["codes"] : {}).merge(name => code).compact
    point.update_columns(address: point.address.merge("codes" => codes))
  end

  def value(point, last) = { "buttons" => Points::Command.remote_buttons(point).size, "last" => last }
end
