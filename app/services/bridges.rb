# Pontes de exposição (integ): o MA mostra pontos escolhidos a outro
# ecossistema (Matter → Apple Casa/Siri, Google Home, Alexa, tudo local).
# Cada ponte é um plugin (`Bridges::Base`, um arquivo em app/services/bridges/)
# registrado em `PLUGINS`, que só descreve os tipos de aparelho (`TYPES`):
#   applies: ->(ponto)          o ponto vira este tipo?
#   state:   ->(ponto, valor)   estado no formato do serviço da ponte;
#   commands: {atributo => ->(ponto, valor)} mudança vinda de lá → [comando,
#             argumento(, outro ponto do mesmo aparelho)] ou nil (já está assim).
# A escolha dos pontos (BridgeExposure), a tela /locais/:id/pontes/:ponte e a
# API do serviço (/api/v1/bridges/:ponte) são comuns. Ponte nova = classe +
# nome aqui.
module Bridges
  PLUGINS = %w[MatterBridge].freeze
  STATUS_TTL = 2.minutes # o serviço manda a situação a cada poucos segundos; sem ela = fora do ar

  module_function

  def plugins = PLUGINS.map { |n| const_get(n) }
  def [](key) = plugins.find { |b| b.key == key.to_s }
  def keys = plugins.map(&:key)

  # Pontos do local que a ponte entende → [[ponto, tipo]].
  def candidates(bridge, site)
    site.points.includes(:device, :area).where(disabled: false).order(:name).filter_map { |p| (t = bridge.type_for(p)) && [ p, t ] }
  end

  # O que o serviço publica: os pontos expostos nos locais, com o estado de agora.
  def devices(bridge, sites)
    BridgeExposure.where(bridge: bridge.key, site_id: sites.select(:id)).includes(point: %i[device area]).filter_map do |e|
      p = e.point
      next if p.disabled || !(type = bridge.type_for(p))

      { "id" => p.id, "type" => type, "name" => e.label, "room" => p.area&.name, "manufacturer" => p.device.manufacturer.presence,
        "reachable" => p.quality != "unavailable", "state" => bridge.state(type, p), "listen" => bridge.listen(type) }.compact
    end
  end

  # Mudança vinda do ecossistema → comando do MA (origem "bridge"). nil = nada a fazer.
  def command!(bridge, point, attribute, value)
    exposed = BridgeExposure.exists?(bridge: bridge.key, point_id: point.id)
    type = exposed && bridge.type_for(point) or raise Points::Command::Error.new(:not_exposed, "Ponto não exposto nesta ponte.")
    cmd, arg, target = bridge.command(type, point, attribute.to_s, value)
    Points::Command.call(target || point, cmd, arg, source: "bridge") if cmd
  end

  # Situação que o serviço manda (código de pareamento, pareada?), por instalação.
  def report_status!(bridge, tenant, data)
    Rails.cache.write(status_key(bridge, tenant), data.to_h.stringify_keys.merge("at" => Time.current.iso8601), expires_in: STATUS_TTL)
  end

  def status(bridge, tenant) = Rails.cache.read(status_key(bridge, tenant))
  def status_key(bridge, tenant) = "bridge:#{bridge.key}:#{tenant.id}"

  class Base
    TYPES = {}.freeze

    class << self
      attr_reader :key, :title, :icon, :description

      def describe(key:, title:, icon:, description:)
        @key = key
        @title = title
        @icon = icon
        @description = description
      end

      def type_for(point) = self::TYPES.find { |_k, t| t[:applies].call(point) }&.first
      def label(type) = self::TYPES.dig(type, :label) || type
      def state(type, point) = self::TYPES.fetch(type)[:state].call(point, point.value)
      def listen(type) = self::TYPES.fetch(type)[:commands].to_h.keys

      def command(type, point, attribute, value)
        fn = self::TYPES.fetch(type)[:commands].to_h[attribute] or raise Points::Command::Error.new(:invalid_command, "#{attribute} não vale em #{label(type)}.")
        fn.call(point, value)
      end

      # Escala do ponto ↔ 0–100 % (e de volta, arredondado ao tipo do ponto).
      def to_pct(p, v)
        min, max = (p.min || 0).to_f, (p.max || 100).to_f
        max > min && v.is_a?(Numeric) ? (((v - min) / (max - min)) * 100).round.clamp(0, 100) : 0
      end

      def from_pct(p, pct)
        min, max = (p.min || 0).to_f, (p.max || 100).to_f
        v = min + ((max - min) * pct.to_f.clamp(0, 100) / 100.0)
        p.data_type == "integer" ? v.round : v.round(2)
      end

      # Outro ponto do mesmo aparelho com a capacidade (liga/desliga da lâmpada colorida).
      def sibling(p, capability) = p.device.points.find { |s| s.capability == capability && !s.disabled && s.id != p.id }
    end
  end
end
