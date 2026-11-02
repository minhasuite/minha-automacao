# Cards de terceiros (ondaA2 A20; os "custom cards" do HACS). O pacote
# declara `{type: "card", key, name, url, sha256, element}`: o JS é baixado
# uma vez, conferido pelo SHA-256 e guardado pelo próprio hash
# (`storage/cards/<sha>.js`). Na tela o card roda num iframe `sandbox`
# (origem opaca: sem cookie, sem DOM nem API do Minha Automação) com
# `integrity` no script, e recebe só o estado dos pontos escolhidos no
# formato `hass.states` do HA (setConfig + hass), então muitos cards do HACS
# que só mostram estado funcionam sem mudança.
module Cards
  MAX_BYTES = 512 * 1024
  SHA = /\A\h{64}\z/
  ELEMENT = /\A[a-z][a-z0-9]*(-[a-z0-9]+)+\z/

  module_function

  def dir = Rails.root.join("storage", "cards").to_s
  def path(sha) = File.join(dir, "#{sha}.js")
  def integrity(sha) = "sha256-#{[ [ sha ].pack('H*') ].pack('m0')}"

  # Aceita hexa ou "sha256-<base64>" (o formato do atributo integrity) → hexa.
  def hex(value)
    v = value.to_s.strip
    return v.downcase if v.match?(SHA)

    b64 = v.delete_prefix("sha256-")
    bin = b64.unpack1("m0") if b64.match?(%r{\A[A-Za-z0-9+/]{43}=\z})
    bin&.unpack1("H*")
  rescue ArgumentError
    nil
  end

  # Baixa (SafeHttp: nada de rede interna), confere o hash e guarda. → hexa.
  def fetch!(url, sha256)
    want = hex(sha256) or raise Packages::Error, I18n.t("cards.errors.sha")
    return want if File.exist?(path(want))

    res = SafeHttp.get(url, timeout: 15)
    raise Packages::Error, I18n.t("cards.errors.download", status: res.status) if res.status >= 400
    raise Packages::Error, I18n.t("cards.errors.too_big") if res.body.bytesize > MAX_BYTES

    got = Digest::SHA256.hexdigest(res.body)
    raise Packages::Error, I18n.t("cards.errors.mismatch", want: want.first(12), got: got.first(12)) unless ActiveSupport::SecurityUtils.secure_compare(got, want)

    FileUtils.mkdir_p(dir)
    File.binwrite(path(want), res.body)
    want
  rescue SafeHttp::Error => e
    raise Packages::Error, I18n.t("cards.errors.download", status: e.message)
  end

  # O arquivo ainda bate com o nome? (nil = sumiu ou mexeram nele)
  def read(sha)
    return nil unless sha.to_s.match?(SHA) && File.exist?(path(sha))

    body = File.binread(path(sha))
    body if Digest::SHA256.hexdigest(body) == sha
  end

  # Cards instalados no local: [{ "ref" => "pacote/card", "name", "sha", "element" }].
  def available(site)
    site.packages.ordered.flat_map do |pkg|
      pkg.items.select { |i| i["type"] == "card" }.filter_map do |i|
        ref = pkg.ref("card", i["key"]) or next
        { "ref" => "#{pkg.key}/#{i['key']}", "name" => i["name"].presence || i["key"], "sha" => ref["id"], "element" => i["element"] }
      end
    end
  end

  # Estado no formato do HA (`hass.states`): entity_id = chave do ponto.
  def states(points)
    points.to_h do |p|
      [ p.key, { "entity_id" => p.key, "state" => state_text(p), "attributes" => p.attrs.to_h.merge("friendly_name" => p.name, "unit_of_measurement" => p.unit).compact,
                 "last_changed" => p.changed_at&.iso8601 } ]
    end
  end

  def state_text(p)
    return "unavailable" unless p.quality == "good"
    return (p.value ? "on" : "off") if p.data_type == "bool"

    p.value.is_a?(Hash) || p.value.is_a?(Array) ? p.value.to_json : p.value.to_s
  end

  # Documento do iframe: CSP só com o script do card (pelo hash) e o estado em `window.MA`.
  def srcdoc(d, base_url)
    boot = { config: d["config"], hass: { states: d["states"], language: I18n.locale.to_s, themes: { darkMode: false } } }
    tag = ERB::Util.json_escape(d["element"].to_json)
    <<~HTML
      <!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src #{base_url}/cartoes/ 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: https:; font-src data:">
      <style>html,body{margin:0;background:transparent;font-family:system-ui,sans-serif;color:#1e1a38}</style></head><body>
      <script>window.MA=#{ERB::Util.json_escape(boot.to_json)};</script>
      <script src="#{base_url}/cartoes/#{d['sha']}.js" integrity="#{d['integrity']}" crossorigin="anonymous"></script>
      <script>(function(){var t=#{tag};customElements.whenDefined(t).then(function(){var el=document.createElement(t);if(el.setConfig)el.setConfig(window.MA.config);el.hass=window.MA.hass;document.body.appendChild(el)})})();</script>
      </body></html>
    HTML
  end
end
