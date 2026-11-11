# Double Take pelo MQTT (Mqtt::Listener::DISCOVERY): `<tópico>/matches/<nome>`
# com o JSON do reconhecimento ({camera, match: {name, confidence}}). Cada
# mensagem liga o "Rosto visto" da pessoa (sensor de pulso, `hold_s`), anota
# a câmera e dispara o evento `face_recognized`. Plugin em
# Integrations::DoubleTakePlugin.
module DoubleTake
  EVENT = "face_recognized".freeze

  module_function

  def prefixes = Integration.where(driver: "double_take").map { |i| i.settings["topic"].presence || "double-take" }.uniq
  def topics = prefixes.map { |t| "#{t}/matches/+" }
  def handles?(topic) = prefixes.any? { |t| topic.start_with?("#{t}/matches/") }

  def handle(topic, payload)
    prefix, name = topic.split("/matches/", 2)
    msg = JSON.parse(payload.to_s)
    msg = {} unless msg.is_a?(Hash)
    name = Integrations::DoubleTakePlugin.slug(msg.dig("match", "name").presence || name)
    return if name.blank? || name == "unknown"

    data = { "name" => name, "camera" => msg["camera"].to_s, "confidence" => msg.dig("match", "confidence")&.to_f, "zones" => Array(msg["zones"]) }.compact
    devices(prefix, name).each do |d|
      ActsAsTenant.with_tenant(d.tenant) do
        d.update_columns(status: "online", last_seen_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
        d.points.reject(&:disabled).each do |p|
          case p.address["field"]
          when "seen" then p.report!(true)
          when "camera" then p.report!(data["camera"]) if data["camera"].present?
          when "last" then p.report!(data.merge("at" => Time.current.iso8601))
          end
        end
        Automations::Triggers.event(d.site_id, EVENT, data)
      end
    end
  rescue JSON::ParserError
    nil
  end

  def devices(prefix, name)
    ActsAsTenant.without_tenant do
      Device.where(driver: "double_take", disabled: false, removed_at: nil).where("address->>'topic' = ? AND address->>'name' = ?", prefix, name)
            .includes(:points, :tenant).to_a
    end
  end
end
