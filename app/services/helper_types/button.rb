module HelperTypes
  # Botão (input_button do HA): apertar é um evento. O valor é a hora do
  # aperto, então o gatilho "Ponto mudou" (sem de/para) dispara a cada aperto.
  class Button < Plugin
    describe key: "button", title: "Botão", icon: "lightning-bolt", capability: "command",
             description: "Um botão para apertar na tela ou no app e disparar automações."

    def self.assign(point, _form) = point.writable = true
    def self.new_value(_cmd) = Time.current.iso8601(3)
  end
end
