# Reprodução das gravações do DVR/NVR (cameras2): o perfil do fabricante é dado
# (`config/device_maps/dvr.yml`), nunca `case` por marca. O perfil diz como tirar o
# canal do caminho do ponto, o caminho RTSP da reprodução e quem lista as gravações
# (`finder`, em `Cameras::Timeline::FINDERS`). A URL com senha só existe aqui, na hora
# de pôr a fonte no go2rtc (`Drivers::Go2rtc.playback!`), nunca no banco, log ou tela.
module Cameras
  module Playback
    PROFILES = YAML.load_file(Rails.root.join("config/device_maps/dvr.yml")).freeze

    module_function

    # [chave, perfil] do aparelho: `address.playback` escolhe (ou "off" desliga); senão,
    # o primeiro cujo `match` casa com o caminho ou cujo `manufacturers` tem o fabricante.
    def profile(point)
      d = point.device
      return unless d.driver == "go2rtc" && point.address["on_demand"].blank?

      chosen = d.address["playback"].presence
      return if chosen == "off"
      return (PROFILES[chosen] ? [ chosen, PROFILES[chosen] ] : nil) if chosen

      path = point.address["path"].to_s
      PROFILES.find do |_, p|
        (p["match"].present? && path.match?(Regexp.new(p["match"]))) ||
          Array(p["manufacturers"]).any? { |m| m.casecmp?(d.manufacturer.to_s) }
      end
    end

    def channel(point)
      _, p = profile(point)
      return if p.nil? || p["channel"].blank?

      point.address["path"].to_s[Regexp.new(p["channel"]), 1]&.to_i&.then { |n| n.positive? ? n : nil }
    end

    def available?(point) = channel(point).present?

    def zone(point) = ActiveSupport::TimeZone[point.site.timezone.to_s] || Time.zone

    # Fonte RTSP da reprodução a partir de `from` (hora do DVR = fuso do local).
    def source(point, from)
      _, p = profile(point)
      ch = channel(point) or raise Error, I18n.t("cameras.playback.unavailable")
      main = Drivers::Go2rtc.source(point) or raise Error, I18n.t("cameras.playback.unavailable")
      base = main[%r{\A[a-z]+://[^/]+}i]
      from = from.in_time_zone(zone(point))
      to = from + p["window_s"].to_i.clamp(60, 86_400).seconds
      fmt = p["time_format"]
      path = p["playback"].gsub("{channel}", ch.to_s).gsub("{start}", from.strftime(fmt)).gsub("{end}", to.strftime(fmt))
      "#{base}#{path}#{p['source_suffix']}"
    end
  end
end
