module Alexa
  # Lote 9: a última fala às Echo da conta vira atributos do ponto `speaker`,
  # com os nomes do alexa_media (`last_called`, `last_called_summary`,
  # `last_called_timestamp` em ms), para o gatilho "Ponto mudou" por
  # atributo ("Alexa, boa noite" em qualquer Echo → rotina daqui). A Echo que
  # ouviu fica com `last_called` verdadeiro e as outras com falso.
  #
  # Lê o histórico de voz a cada minuto (AlexaPlugin.tick), e só quando alguma
  # automação ligada do local escuta um atributo dessas Echo: sem ninguém
  # escutando, nada sai para a Amazon.
  module LastCalled
    WINDOW = 10.minutes

    module_function

    def refresh!(integration, now = Time.current, client: nil)
      points = Point.joins(:device).includes(:device).where(devices: { integration_id: integration.id, driver: "alexa" }, capability: "speaker").to_a
      return if points.empty? || !listened?(points)

      last = (client || Drivers::Alexa.client_for(integration)).voice_history(since: now - WINDOW, to: now).first or return
      ms = (last[:at].to_f * 1000).to_i
      points.each do |p|
        attrs = if p.device.external_id == last[:serial]
          p.attrs.to_h.merge("last_called" => true, "last_called_summary" => last[:text], "last_called_timestamp" => ms)
        else
          p.attrs.to_h.merge("last_called" => false)
        end
        p.report_attrs!(attrs)
      end
    end

    # Alguma automação ligada tem gatilho por atributo numa destas Echo?
    def listened?(points)
      ids = points.map(&:id)
      Automation.where(site_id: points.first.site_id, enabled: true).where("definition::text LIKE ?", "%\"attribute\"%").any? do |a|
        Array(a.definition["triggers"]).any? { |t| t["attribute"].present? && ids.include?(t["point"]) }
      end
    end
  end
end
