# Thread (ondaC1, C3): OpenThread Border Router pela API REST (a mesma que o
# add-on OTBR do HA e o container `otbr` expõem na porta 8081). Lê o nó
# (estado, rede) e o dataset ativo (TLV em hex), forma uma rede nova e liga
# o Thread. O dataset é a "credencial" da rede: guardado cifrado na
# integração e mandado ao Matter Server (`set_thread_dataset`) para os
# aparelhos Matter-sobre-Thread entrarem na mesma rede.
module Otbr
  Error = Class.new(StandardError)
  TIMEOUT = 8
  # Tipos TLV do dataset (Thread 1.3, MeshCoP).
  TLV = { 0 => "channel", 1 => "pan_id", 2 => "ext_pan_id", 3 => "network_name", 4 => "pskc", 5 => "network_key",
          7 => "mesh_local_prefix", 12 => "security_policy", 14 => "active_timestamp", 53 => "channel_mask" }.freeze
  SECRET_TLVS = %w[network_key pskc].freeze

  module_function

  def request(base, method, path, body: nil, accept: "application/json")
    uri = URI.join("#{base.to_s.chomp('/')}/", path.delete_prefix("/"))
    req = Net::HTTP.const_get(method.to_s.capitalize).new(uri)
    req["Accept"] = accept
    if body
      req["Content-Type"] = body.is_a?(String) ? "text/plain" : "application/json"
      req.body = body.is_a?(String) ? body : body.to_json
    end
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: TIMEOUT, read_timeout: TIMEOUT) { |h| h.request(req) }
    raise Error, "OTBR #{method.upcase} #{path}: #{res.code}" unless res.is_a?(Net::HTTPSuccess)

    res.body.to_s
  rescue SocketError, SystemCallError, Net::OpenTimeout, Net::ReadTimeout, IOError => e
    raise Error, "Sem resposta do OTBR (#{e.class.name.demodulize})."
  end

  def node(base) = JSON.parse(request(base, :get, "node").presence || "{}")
  def dataset_hex(base) = request(base, :get, "node/dataset/active", accept: "text/plain").strip.presence

  # Rede nova com os padrões do OTBR (canal e chaves aleatórios) e liga o Thread.
  def form!(base, name)
    request(base, :put, "node/dataset/active", body: { "NetworkName" => name.to_s.first(16) })
    request(base, :put, "node/state", body: "enable")
  end

  # TLV em hex → {campo → valor} (chave e PSKc mascaradas para a tela).
  def parse(hex, reveal: false)
    bin = [ hex.to_s ].pack("H*")
    out = {}
    pos = 0
    while pos + 2 <= bin.bytesize
      type, len = bin.byteslice(pos, 2).unpack("CC")
      value = bin.byteslice(pos + 2, len).to_s
      pos += 2 + len
      name = TLV[type] or next
      out[name] = case name
      when "channel" then value.byteslice(1, 2).to_s.unpack1("n")
      when "pan_id" then format("0x%04X", value.unpack1("n").to_i)
      when "network_name" then value.dup.force_encoding("UTF-8").scrub
      when "active_timestamp" then value.byteslice(0, 6).to_s.rjust(8, "\0").unpack1("Q>")
      else reveal || !SECRET_TLVS.include?(name) ? value.unpack1("H*") : "••••"
      end
    end
    out
  end

  def valid_hex?(hex) = hex.to_s.match?(/\A(\h\h)+\z/) && parse(hex).key?("network_name")
end
