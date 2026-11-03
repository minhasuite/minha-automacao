require "socket"

module Integrations
  # Nobreak pelo NUT (catalogo): Network UPS Tools (`upsd`, TCP 3493, texto).
  # Cada UPS do servidor vira um aparelho com carga da bateria, autonomia,
  # tensões, carga de saída e estado (rede, bateria, bateria fraca). Só leitura.
  class NutPlugin < SchemaPlugin
    describe key: "nut", title: "Nobreak (NUT)", icon: "battery",
             description: "Nobreaks ligados a um servidor NUT (Network UPS Tools: Synology, Raspberry, pfSense…): bateria, autonomia, tensão, carga e se está na rede ou na bateria."
    texts "pt-BR" => { points: { runtime: "Autonomia", input_voltage: "Tensão de entrada", output_voltage: "Tensão de saída", load: "Carga", on_battery: "Na bateria",
                                 low_battery: "Bateria fraca" }, no_ups: "O servidor NUT não tem nenhum nobreak." },
          en: { title: "UPS (NUT)", description: "UPSes attached to a NUT server (Network UPS Tools: Synology, Raspberry, pfSense…): battery, runtime, voltage, load and whether it's on mains or battery.",
                points: { runtime: "Runtime", input_voltage: "Input voltage", output_voltage: "Output voltage", load: "Load", on_battery: "On battery", low_battery: "Low battery" },
                no_ups: "The NUT server has no UPS." },
          es: { title: "UPS (NUT)", description: "UPS conectados a un servidor NUT (Network UPS Tools: Synology, Raspberry, pfSense…): batería, autonomía, tensión, carga y si está en la red o en la batería.",
                points: { runtime: "Autonomía", input_voltage: "Tensión de entrada", output_voltage: "Tensión de salida", load: "Carga", on_battery: "En batería", low_battery: "Batería baja" },
                no_ups: "El servidor NUT no tiene ningún UPS." }
    field :host, required: true
    field :port, :number, default: 3493
    field :username
    field :password, secret: true

    # Variável do NUT → [campo, opções do ponto].
    VARS = {
      "battery.charge" => [ "battery", { unit: "%", device_class: "battery", state_class: "measurement" } ],
      "battery.runtime" => [ "runtime", { unit: "min", state_class: "measurement" } ],
      "input.voltage" => [ "input_voltage", { unit: "V", device_class: "voltage", state_class: "measurement" } ],
      "output.voltage" => [ "output_voltage", { unit: "V", device_class: "voltage", state_class: "measurement" } ],
      "ups.load" => [ "load", { unit: "%", state_class: "measurement" } ],
      "ups.realpower" => [ "power", { unit: "W", device_class: "power", state_class: "measurement" } ]
    }.freeze

    class << self
      # Pergunta(s) → linhas da resposta (até o END/OK de cada uma).
      def session(integration)
        Socket.tcp(conf(integration, :host), conf(integration, :port).to_i, connect_timeout: 5) do |s|
          talk = lambda do |cmd|
            s.write("#{cmd}\n")
            lines = []
            loop do
              raise Integrations::Error, "NUT: sem resposta" unless s.wait_readable(5)

              line = s.gets or raise(Integrations::Error, "NUT: conexão fechada")
              line = line.chomp
              raise Integrations::Error, "NUT: #{line}" if line.start_with?("ERR")

              lines << line
              break if line.start_with?("END", "OK") || (lines.one? && !line.start_with?("BEGIN"))
            end
            lines
          end
          if (user = conf(integration, :username)).present?
            talk.call("USERNAME #{user}")
            talk.call("PASSWORD #{conf(integration, :password)}")
          end
          yield talk
        end
      rescue *LanPlugin::NET_ERRORS => e
        raise Integrations::Error, "NUT: #{e.class.name.demodulize}"
      end

      def parse(lines, prefix) = lines.filter_map { |l| l.match(/\A#{prefix} (\S+)(?: (\S+))? "(.*)"\z/) }.to_h { |m| [ m[2] || m[1], m[3] ] }

      def vars(talk, ups) = parse(talk.call("LIST VAR #{ups}"), "VAR #{Regexp.escape(ups)}")

      def entries(integration)
        session(integration) do |talk|
          list = parse(talk.call("LIST UPS"), "UPS")
          raise Integrations::Error, text(:no_ups) if list.empty?

          list.map do |ups, desc|
            v = vars(talk, ups)
            pts = VARS.filter_map { |var, (f, opts)| point(f, **opts) if v.key?(var) }
            entry(id: "nut:#{conf(integration, :host)}:#{ups}", name: desc.presence || ups, manufacturer: v["device.mfr"] || v["ups.mfr"] || title,
                  model: v["device.model"] || v["ups.model"], address: { "ups" => ups }, poll_s: 30,
                  points: pts + [ point("on_battery", "problem", icon: "battery"), point("low_battery", "problem", icon: "battery"), point("status", "text", writable: false) ])
          end
        end
      end

      def read(device)
        v = session(device.integration) { |talk| vars(talk, device.address["ups"]) }
        flags = v["ups.status"].to_s.split
        out = VARS.to_h { |var, (f, _)| [ f, v[var] && (var == "battery.runtime" ? (v[var].to_f / 60).round(1) : v[var].to_f) ] }
        out.merge("on_battery" => flags.include?("OB"), "low_battery" => flags.include?("LB"), "status" => v["ups.status"])
      end
    end
  end
end
