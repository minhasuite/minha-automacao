# Automação de dispositivo (ondaA1, A6; os gatilhos e condições de
# aparelho do HA): em vez de "ponto mudou para true", o editor oferece o que
# o aparelho faz em palavras ("Movimento detectado", "Botão: clique duplo",
# "Porta abriu"), tirado da capacidade de cada ponto, que já vem dos mapas de
# aparelho (config/device_maps/*.yml) e dos plugins de integração. Ações de
# aparelho já são o "Comandar ponto" (os comandos de cada ponto).
#
# Registro aberto: capacidade nova = entrada em TRIGGERS/CONDITIONS
# ({evento => [chave do texto, ->(valor, anterior) { … }]}); o ponto de evento
# (botão, controle) oferece as opções que o mapa trouxe (`points.options`).
class DeviceAutomations
  extend PluginTexts

  ON = ->(v, _was) { v == true }
  OFF = ->(v, _was) { v == false }
  IS = ->(x) { ->(v, _was) { v.to_s == x } }

  TRIGGERS = {
    "onoff" => { "turned_on" => ON, "turned_off" => OFF },
    "contact" => { "opened" => ON, "closed" => OFF },
    "motion" => { "detected" => ON, "cleared" => OFF },
    "tamper" => { "tampered" => ON, "tamper_cleared" => OFF },
    "problem" => { "problem" => ON, "problem_cleared" => OFF },
    "gate" => { "gate_open" => IS.("open"), "gate_closed" => IS.("closed"), "gate_opening" => IS.("opening") },
    "vacuum" => { "cleaning" => IS.("cleaning"), "docked" => IS.("docked"), "vacuum_error" => IS.("error") },
    "measure" => { "changed" => ->(v, was) { v != was } },
    "dimmer" => { "changed" => ->(v, was) { v != was } },
    "detection" => { "detected_any" => ->(v, _was) { !v.nil? } }
  }.freeze

  CONDITIONS = {
    "onoff" => { "is_on" => true, "is_off" => false },
    "contact" => { "is_open" => true, "is_closed" => false },
    "motion" => { "has_motion" => true, "no_motion" => false },
    "gate" => { "gate_is_open" => "open", "gate_is_closed" => "closed" }
  }.freeze

  texts "pt-BR" => { turned_on: "Ligou", turned_off: "Desligou", opened: "Abriu", closed: "Fechou", detected: "Movimento detectado", cleared: "Movimento parou",
                     tampered: "Violação detectada", tamper_cleared: "Violação parou", problem: "Problema começou", problem_cleared: "Problema acabou",
                     gate_open: "Portão abriu", gate_closed: "Portão fechou", gate_opening: "Portão abrindo", cleaning: "Começou a limpar", docked: "Voltou para a base",
                     vacuum_error: "Robô com erro", changed: "Valor mudou", detected_any: "Detectou algo", press: "Botão: %{option}", any_press: "Botão: qualquer toque",
                     is_on: "Está ligado", is_off: "Está desligado", is_open: "Está aberto", is_closed: "Está fechado", has_motion: "Tem movimento", no_motion: "Sem movimento",
                     gate_is_open: "Portão aberto", gate_is_closed: "Portão fechado", unknown: "evento não serve para este ponto." },
        en: { turned_on: "Turned on", turned_off: "Turned off", opened: "Opened", closed: "Closed", detected: "Motion detected", cleared: "Motion cleared",
              tampered: "Tamper detected", tamper_cleared: "Tamper cleared", problem: "Problem started", problem_cleared: "Problem cleared",
              gate_open: "Gate opened", gate_closed: "Gate closed", gate_opening: "Gate opening", cleaning: "Started cleaning", docked: "Returned to dock",
              vacuum_error: "Vacuum error", changed: "Value changed", detected_any: "Detected something", press: "Button: %{option}", any_press: "Button: any press",
              is_on: "Is on", is_off: "Is off", is_open: "Is open", is_closed: "Is closed", has_motion: "Has motion", no_motion: "No motion",
              gate_is_open: "Gate open", gate_is_closed: "Gate closed", unknown: "event does not fit this point." },
        es: { turned_on: "Se encendió", turned_off: "Se apagó", opened: "Se abrió", closed: "Se cerró", detected: "Movimiento detectado", cleared: "Movimiento terminó",
              tampered: "Violación detectada", tamper_cleared: "Violación terminó", problem: "Problema empezó", problem_cleared: "Problema terminó",
              gate_open: "Portón abrió", gate_closed: "Portón cerró", gate_opening: "Portón abriendo", cleaning: "Empezó a limpiar", docked: "Volvió a la base",
              vacuum_error: "Robot con error", changed: "El valor cambió", detected_any: "Detectó algo", press: "Botón: %{option}", any_press: "Botón: cualquier toque",
              is_on: "Está encendido", is_off: "Está apagado", is_open: "Está abierto", is_closed: "Está cerrado", has_motion: "Hay movimiento", no_motion: "Sin movimiento",
              gate_is_open: "Portón abierto", gate_is_closed: "Portón cerrado", unknown: "el evento no sirve para este punto." }

  class << self
    # {evento => rótulo} que o ponto oferece como gatilho.
    def triggers_for(point)
      return {} unless point
      return { "press" => text(:any_press) }.merge(point.option_values.to_h { |o| [ "press:#{o}", text(:press, option: o) ] }) if point.capability == "event"

      TRIGGERS.fetch(point.capability, {}).keys.index_with { |k| text(k) }
    end

    def conditions_for(point) = point ? CONDITIONS.fetch(point.capability, {}).keys.index_with { |k| text(k) } : {}

    def fires?(point, event, value, was)
      if point.capability == "event"
        got = value.is_a?(Hash) ? value["type"] || value["event"] : value
        return event == "press" ? !got.nil? : got.to_s == event.delete_prefix("press:")
      end

      TRIGGERS.dig(point.capability, event)&.call(value, was) || false
    end

    def holds?(point, condition, value)
      want = CONDITIONS.dig(point.capability, condition)
      !want.nil? && value == want
    end
  end
end
