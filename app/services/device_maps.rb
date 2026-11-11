# Mapas de dados de aparelho (config/device_maps/*.yml) mais o que os
# pacotes instalados da instalação acrescentam (Pacote 3, item
# `device_map`). Pacote só soma dados nas seções de `MERGEABLE` (códigos,
# categorias, propriedades); padrões com regex e o que pular ficam só no
# arquivo. Mapa novo = arquivo + linha em `FILES` e `MERGEABLE`.
module DeviceMaps
  FILES = { "tuya" => "config/device_maps/tuya.yml", "miot" => "config/device_maps/miot.yml" }.freeze
  MERGEABLE = { "tuya" => %w[codes categories streams gateways aliases], "miot" => %w[properties vacuum_events] }.freeze
  TTL = 60

  module_function

  def base(name) = (@base ||= {})[name] ||= YAML.load_file(Rails.root.join(FILES.fetch(name))).freeze

  # Mapa da instalação atual (arquivo + pacotes).
  def get(name) = apply(name, base(name))

  # `base` (o mapa do arquivo que o serviço já carregou) + o dos pacotes da
  # instalação atual. Sem pacote, devolve o próprio `base`.
  def apply(name, base)
    list = cached_extras(name)
    list.empty? ? base : list.reduce(base) { |acc, data| merge(acc, data) }
  end

  # Guardado por 60 s por instalação (install!/uninstall! limpam).
  def cached_extras(name)
    tenant = ActsAsTenant.current_tenant&.id or return []
    @cache ||= {}
    hit = @cache[[ name, tenant ]]
    return hit[1] if hit && hit[0] > monotonic

    extras(name).tap { |list| @cache[[ name, tenant ]] = [ monotonic + TTL, list ] }
  end

  def reset! = (@cache = {})

  def extras(name)
    Package.pluck(:manifest).flat_map do |m|
      Array(m["items"]).select { |i| i["type"] == "device_map" && i["map"] == name }.map { |i| i["data"].to_h.slice(*MERGEABLE[name]) }
    end
  end

  def merge(acc, data)
    acc.merge(data) do |_k, a, b|
      if a.is_a?(Hash) && b.is_a?(Hash) then a.merge(b)
      elsif a.is_a?(Array) && b.is_a?(Array) then (a + b).uniq
      else b
      end
    end
  end

  # Só dados (texto, número, sim/não, listas e objetos disso).
  def plain?(v, depth = 0)
    return false if depth > 6

    case v
    when Hash then v.all? { |k, x| k.is_a?(String) && plain?(x, depth + 1) }
    when Array then v.all? { |x| plain?(x, depth + 1) }
    else v.nil? || v.is_a?(String) || v.is_a?(Numeric) || v == true || v == false
    end
  end

  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end
