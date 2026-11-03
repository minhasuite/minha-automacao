module Drivers
  # Acessório HomeKit (ondaC1, C5) pelo Hap::Client: endereço do acessório e
  # pareamento na integração; ponto = {aid, iid, type}. Leitura periódica
  # (GET /characteristics de todos os pontos numa sessão) e comando por PUT.
  class Homekit
    def self.read(integration, devices)
      points = devices.flat_map { |d| d.points.reject(&:disabled) }
      return if points.empty?

      values = Integrations::HomekitPlugin.session(integration) { |s| s.characteristics(points.map { |p| "#{p.address['aid']}.#{p.address['iid']}" }) }
      by_id = values.index_by { |c| [ c["aid"], c["iid"] ] }
      devices.each { |d| d.update_columns(status: "online", last_seen_at: Time.current) }
      points.each { |p| (c = by_id[[ p.address["aid"], p.address["iid"] ]]) && (v = ::Hap::Map.value(p, c["value"])).then { |x| p.report!(x) unless x.nil? } }
    rescue ::Hap::Error, *Integrations::LanPlugin::NET_ERRORS => e
      raise Integrations::Error, e.message
    end

    def self.poll(device) = read(device.integration, [ device ])
    def self.unavailable!(device) = Drivers.offline!(device)

    def execute(point, command, value)
      v = Points::Command.new(point, command, value).new_value
      Integrations::HomekitPlugin.session(point.device.integration) do |s|
        s.put([ { "aid" => point.address["aid"], "iid" => point.address["iid"], "value" => ::Hap::Map.raw(point, v) } ])
      end
      point.report!(v)
    rescue ::Hap::Error, *Integrations::LanPlugin::NET_ERRORS => e
      raise Integrations::Error, e.message
    end
  end
end
