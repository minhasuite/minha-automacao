require "yaml"
require "json"

# Catálogo de aplicativos (F8g): um manifesto YAML por app em config/apps/
# (nome do arquivo = chave). Ruby puro, sem Rails: o supervisor
# (supervisor/server.rb) carrega este mesmo arquivo para validar as opções e
# montar o container. O manifesto fica na imagem e não é editável pela web;
# o usuário só preenche as opções previstas no schema dele.
module AppCatalog
  DIR = File.expand_path("../config/apps", __dir__)
  PREFIX = "ma-app-".freeze
  LABEL = "minha-automacao.app".freeze
  # Variáveis do servidor que um manifesto pode repassar ao app (server_env).
  SERVER_ENV = %w[MQTT_PASSWORD Z2M_FRONTEND_TOKEN].freeze
  # Portas do próprio servidor (web, banco, MQTT, mídia do go2rtc).
  RESERVED_PORTS = [ 80, 443, 1883, 1984, 3000, 5432, 8099, 8555 ].freeze
  DEVICE_RE = %r{\A/dev/(serial/by-id/[\w.:-]+|tty(USB|ACM)\d{1,2})\z}
  TYPES = %w[string integer boolean enum device].freeze
  NETWORKS = %w[apps bridge].freeze
  KEYS = %w[name category icon description image version system network ports volumes options env
            server_env web_ui health shm_mb].freeze

  class Invalid < StandardError; end

  module_function

  def all = @all ||= Dir[File.join(DIR, "*.yml")].sort.map { |f| Manifest.load(f) }
  def find(key) = all.find { |m| m.key == key.to_s }
  def categories = all.map(&:category).uniq.sort

  def search(query, category = nil)
    q = query.to_s.strip.downcase
    all.select do |m|
      (category.to_s.empty? || m.category == category) &&
        (q.empty? || [ m.name, m.description, m.category ].any? { |t| t.downcase.include?(q) })
    end
  end

  class Manifest
    attr_reader :key, :data

    def self.load(path) = new(File.basename(path, ".yml"), YAML.safe_load_file(path))

    def initialize(key, data)
      @key = key
      @data = data
      validate!
    end

    %w[name category icon description image version network shm_mb web_ui health].each { |k| define_method(k) { data[k] } }
    def system_service = data["system"]
    def system? = !system_service.nil?
    def ports = data.fetch("ports", [])
    def volumes = data.fetch("volumes", [])
    def options = data.fetch("options", [])
    def image_ref = "#{image}:#{version}"
    def container_name = "#{PREFIX}#{key}"
    def volume_name(vol) = "#{PREFIX}#{key}-#{vol['name']}"

    # Opções vindas de fora → [opções limpas, {chave → erro}]. Só as chaves do
    # schema passam; segredo em branco mantém o atual.
    def clean_options(input, current = {})
      input = (input || {}).to_h { |k, v| [ k.to_s, v ] }
      errors = {}
      clean = options.to_h do |o|
        k = o["key"]
        raw = input[k]
        raw = current[k] if o["secret"] && blank?(raw)
        raw = o["default"] if blank?(raw)
        value, err = cast(o, raw)
        errors[k] = err if err
        [ k, value ]
      end
      [ clean, errors ]
    end

    # Opções que podem ir para a tela/label (segredo vira nil).
    def public_options(opts) = opts.to_h { |k, v| [ k, options.find { |o| o["key"] == k }&.dig("secret") ? nil : v ] }

    # Corpo do POST /containers/create do Docker. Tudo vem do manifesto; das
    # opções só os valores (env e caminho de device previstos no schema).
    def container_body(opts, network:, restart:, server_env: {})
      env = data.fetch("env", {}).dup
      data.fetch("server_env", {}).each { |var, src| env[var] = server_env[src].to_s }
      options.each { |o| env[o["env"]] = opts[o["key"]].to_s if o["env"] && !opts[o["key"]].nil? }
      devices = options.select { |o| o["type"] == "device" && opts[o["key"]] }
                       .map { |o| { "PathOnHost" => opts[o["key"]], "PathInContainer" => o["path"], "CgroupPermissions" => "rwm" } }
      {
        "Image" => image_ref,
        "Env" => env.map { |k, v| "#{k}=#{v}" },
        "Labels" => { LABEL => key, "minha-automacao.version" => version.to_s,
                      "minha-automacao.options" => JSON.generate(public_options(opts)) },
        "ExposedPorts" => ports.to_h { |p| [ port_spec(p), {} ] },
        "Healthcheck" => health && { "Test" => health["test"], "Interval" => health.fetch("interval_s", 30) * 1_000_000_000 },
        "HostConfig" => {
          "Binds" => volumes.map { |v| "#{volume_name(v)}:#{v['path']}" },
          "PortBindings" => ports.to_h { |p| [ port_spec(p), [ { "HostPort" => p["host"].to_s } ] ] },
          "Devices" => devices,
          "RestartPolicy" => { "Name" => restart },
          "NetworkMode" => network,
          "ShmSize" => shm_mb && shm_mb * 1024 * 1024,
          "Privileged" => false
        }.compact
      }.compact
    end

    private

    def port_spec(port) = "#{port['container']}/#{port.fetch('protocol', 'tcp')}"
    def blank?(v) = v.nil? || v == ""

    def cast(opt, raw)
      return [ nil, (opt["required"] ? "obrigatório" : nil) ] if blank?(raw)

      case opt["type"]
      when "boolean" then [ [ true, "true", "1", "on" ].include?(raw), nil ]
      when "integer"
        i = Integer(raw.to_s, exception: false)
        ok = i && (opt["min"].nil? || i >= opt["min"]) && (opt["max"].nil? || i <= opt["max"])
        ok ? [ i, nil ] : [ nil, "número inválido" ]
      when "enum" then opt["choices"].include?(raw.to_s) ? [ raw.to_s, nil ] : [ nil, "opção inválida" ]
      when "device" then DEVICE_RE.match?(raw.to_s) ? [ raw.to_s, nil ] : [ nil, "use /dev/serial/by-id/…" ]
      else
        s = raw.to_s
        ok = s.length <= 200 && !s.match?(/[[:cntrl:]]/) && (opt["pattern"].nil? || Regexp.new(opt["pattern"]).match?(s))
        ok ? [ s, nil ] : [ nil, "valor inválido" ]
      end
    end

    def fail!(what) = raise(Invalid, "#{key}: #{what}")

    def validate!
      fail!("chave") unless key.match?(/\A[a-z0-9_]{2,40}\z/)
      fail!("campos desconhecidos #{data.keys - KEYS}") unless (data.keys - KEYS).empty?
      %w[name category icon description image version].each { |k| fail!(k) if data[k].to_s.empty? }
      fail!("image") unless image.match?(%r{\A[a-z0-9][a-z0-9._/-]*\z})
      fail!("version") unless version.is_a?(String) && version.match?(/\A[\w.-]+\z/) && version != "latest"
      fail!("system") unless system_service.nil? || system_service.match?(/\A[a-z0-9_-]+\z/)
      return if system?

      fail!("network") unless NETWORKS.include?(network)
      validate_ports!
      volumes.each { |v| fail!("volume") unless v["name"].to_s.match?(/\A[a-z0-9_]+\z/) && v["path"].to_s.match?(%r{\A/[\w./-]+\z}) }
      data.fetch("env", {}).each { |k, v| fail!("env #{k}") unless k.match?(/\A[A-Z][A-Z0-9_]*\z/) && !v.is_a?(Enumerable) }
      data.fetch("server_env", {}).each { |k, v| fail!("server_env #{k}") unless k.match?(/\A[A-Z][A-Z0-9_]*\z/) && SERVER_ENV.include?(v) }
      options.each { |o| validate_option!(o) }
      fail!("health") unless health.nil? || (health["test"].is_a?(Array) && health["test"].all?(String))
      fail!("shm_mb") unless shm_mb.nil? || (shm_mb.is_a?(Integer) && shm_mb.between?(64, 2048))
    end

    def validate_ports!
      ports.each do |p|
        ok = p["container"].is_a?(Integer) && p["host"].is_a?(Integer) && p["host"].between?(1024, 65_535) &&
             !RESERVED_PORTS.include?(p["host"]) && %w[tcp udp].include?(p.fetch("protocol", "tcp"))
        fail!("porta #{p}") unless ok
      end
      fail!("web_ui") unless web_ui.nil? || ports.any? { |p| p["host"] == web_ui["port"] }
    end

    def validate_option!(opt)
      ok = opt["key"].to_s.match?(/\A[a-z0-9_]+\z/) && TYPES.include?(opt["type"]) && !opt["label"].to_s.empty? &&
           (opt["env"].nil? || opt["env"].match?(/\A[A-Z][A-Z0-9_]*\z/)) &&
           (opt["type"] != "enum" || opt["choices"].is_a?(Array)) &&
           (opt["type"] != "device" || opt["path"].to_s.match?(%r{\A/dev/[\w/-]+\z})) &&
           (opt["type"] == "device" || opt["env"])
      fail!("opção #{opt['key']}") unless ok
    end
  end
end
