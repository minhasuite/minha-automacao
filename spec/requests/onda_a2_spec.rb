require "rails_helper"

RSpec::Matchers.define_negated_matcher :not_include, :include unless RSpec::Matchers.method_defined?(:not_include)

# Onda A2 (paridade HA, grupo 7): sistema.
RSpec.describe "Onda A2: sistema" do
  let(:user) { create(:user, role: "owner") }
  let(:tenant) { user.tenant }
  let!(:site) { within(tenant) { create(:site, name: "Casa") } }
  let(:device) { within(tenant) { create(:device, site: site, name: "Medidor") } }

  def sign_in(u = user) = post("/entrar", params: { email: u.email, password: "12345678" })

  describe "A14 ferramenta de estatísticas" do
    let!(:meter) { within(tenant) { create(:point, site: site, device: device, name: "Teste Energia", capability: "measure", unit: "kWh") } }
    let!(:old) { within(tenant) { create(:point, site: site, device: device, name: "Teste Antigo", capability: "measure", history: "none") } }
    let(:hour) { Time.zone.parse("2026-10-10 14:00") }

    before do
      [ hour, hour + 1.hour ].each { |h| ReadingRollup.insert_all([ { point_id: meter.id, bucket: "1h", starts_at: h, sum: 2, count: 1, min: 2, max: 2, avg: 2, last: 2 } ]) }
      ReadingRollup.insert_all([ { point_id: old.id, bucket: "1h", starts_at: hour, sum: 1, count: 1 } ])
      RollupReadingsJob.new.daily(hour.beginning_of_day, hour.end_of_day)
      sign_in
    end

    it "lista, aponta o órfão, ajusta a soma (refaz o dia) e apaga" do
      get "/locais/#{site.id}/ferramentas", params: { aba: "estatisticas" }
      expect(response.body).to include("Teste Energia", "Teste Antigo", "Não grava mais", "2 h")
      expect(within(tenant) { DevTools::Statistics.list(site) }.map(&:issue)).to contain_exactly(nil, "orphan")

      post "/locais/#{site.id}/ferramentas/estatisticas", params: { point_id: meter.id, at: "2026-10-10T14:00", sum: "5,5" }
      expect(flash[:notice]).to include("ajustada")
      day = ReadingRollup.find_by(point_id: meter.id, bucket: "1d")
      expect(day.sum.to_f).to eq(7.5)

      post "/locais/#{site.id}/ferramentas/estatisticas", params: { point_id: meter.id, at: "2026-10-09T03:00", sum: "1" }
      expect(flash[:alert]).to eq("Não há resumo nessa hora.")

      delete "/locais/#{site.id}/ferramentas/estatisticas/#{old.id}"
      expect(ReadingRollup.where(point_id: old.id)).to be_empty
      expect(ReadingRollup.where(point_id: meter.id).count).to eq(3)
    end

    it "membro comum não vê" do
      member = within(tenant) { create(:user, tenant: tenant, role: "member") }
      sign_in(member)
      delete "/locais/#{site.id}/ferramentas/estatisticas/#{old.id}"
      expect(response).to have_http_status(:not_found)
      expect(ReadingRollup.where(point_id: old.id)).to exist
    end
  end

  describe "A13 hardware e rede do host" do
    let(:host) do
      { "hostname" => "casa", "os" => "Debian GNU/Linux 12", "kernel" => "6.1.0", "arch" => "x86_64", "cpu" => "Intel N100", "cpus" => 4,
        "memory_mb" => 8000, "memory_free_mb" => 5000, "uptime_s" => 90_000, "gateway" => "192.168.0.1", "dns" => [ "192.168.0.1" ],
        "interfaces" => [ { "name" => "enp1s0", "mac" => "aa:bb:cc:dd:ee:ff", "state" => "up", "ipv4" => [ "192.168.0.5" ], "ipv6" => [] } ],
        "neighbors" => [ {} ], "serial" => [ { "id" => "usb-zig", "path" => "/dev/serial/by-id/usb-zig", "vid" => "10C4", "pid" => "EA60", "product" => "Teste Zigbee" } ],
        "usb" => [ { "vid" => "8087", "pid" => "0026", "manufacturer" => "Intel", "product" => "Bluetooth" } ] }
    end

    it "mostra máquina, rede e USB ao dono; reinicia com auditoria; sem supervisor explica" do
      sign_in
      get "/configuracoes/hardware"
      expect(response.body).to include("Hardware e rede", "Esta instalação roda sem o supervisor")

      allow(Apps::Supervisor).to receive(:configured?).and_return(true)
      allow(Apps::Supervisor).to receive(:request).with(:get, "/system/host").and_return("data" => host)
      get "/configuracoes/hardware", params: { atualizar: 1 }
      expect(response.body).to include("Debian GNU/Linux 12", "Intel N100 · 4 núcleos", "enp1s0", "192.168.0.5", "Teste Zigbee", "10C4:EA60", "Outros aparelhos USB (1)")

      expect(Apps::Supervisor).to receive(:request).with(:post, "/system/host/reboot").and_return({})
      post "/configuracoes/hardware/reboot"
      expect(flash[:notice]).to eq("Reiniciando a máquina.")
      expect(within(tenant) { AuditEvent.where(action: "host.reboot").count }).to eq(1)
      post "/configuracoes/hardware/formatar"
      expect(response).to have_http_status(:not_found)
    end

    it "só o dono" do
      sign_in(within(tenant) { create(:user, tenant: tenant, role: "admin") })
      get "/configuracoes/hardware"
      expect(response).to redirect_to("/")
    end
  end

  describe "A12 reparos, diagnóstico e logs" do
    let!(:integ) do
      within(tenant) do
        Integration.create!(site: site, driver: "zwave_js", name: "Teste Z-Wave", status: "error", last_error: "recusou em 192.168.0.20",
                            settings: { "url" => "ws://192.168.0.20:3000", "account" => "ana@exemplo.com.br", "token" => "segredo" }, credentials: "cred-secreta")
      end
    end

    before { sign_in }

    it "problema com caminho guiado, correção de um clique e ignorar" do
      get "/configuracoes/saude"
      expect(response.body).to include("Reconfigurar", "/integracoes/#{integ.id}/conectar", "Corrigir", "Ignorar")
      post "/configuracoes/saude/reparar", params: { check: "integrations", item: integ.id }
      expect(flash[:notice]).to eq("Teste Z-Wave: varredura pedida.")
      expect(integ.reload.status).to eq("syncing")
      integ.update_columns(status: "error")

      post "/configuracoes/saude/ignorar", params: { ref: "integrations:#{integ.id}" }
      result = Health.run(tenant.reload, only: "integrations").first
      expect(result.status).to eq("ok")
      expect(result.items.first.ignored).to be(true)
      Health.alert!(tenant)
      expect(within(tenant) { Notification.where("title LIKE ?", "%Teste Z-Wave%") }).to be_empty
      get "/configuracoes/saude"
      expect(response.body).to include("Ignorado", "Mostrar de novo")
      post "/configuracoes/saude/ignorar", params: { ref: "integrations:#{integ.id}", on: "0" }
      expect(Health.run(tenant.reload, only: "integrations").first.status).to eq("error")
      post "/configuracoes/saude/reparar", params: { check: "devices", item: "x" }
      expect(flash[:alert]).to eq("Esse problema não tem correção automática.")
    end

    it "verificação de plugin falso com reparo próprio, sem mudar o núcleo" do
      fake = Class.new(Health::Check) do
        describe key: "teste", label: "Teste", icon: "chip"
        def self.items(_t) = [ item(key: "k1", status: "warn", title: "Teste quebrado", fix: { label: "Abrir", url: "/teste" }) ]
        def self.repair(_t, key) = "consertado #{key}"
      end
      stub_const("Health::Checks::Teste", fake)
      stub_const("Health::CHECKS", Health::CHECKS + [ "Teste" ])
      get "/configuracoes/saude"
      expect(response.body).to include("Teste quebrado", "Abrir", "data-repair=\"teste:k1\"")
      post "/configuracoes/saude/reparar", params: { check: "teste", item: "k1" }
      expect(flash[:notice]).to eq("consertado k1")
    end

    it "diagnóstico em JSON sem credencial, endereço, token nem e-mail" do
      within(tenant) do
        dev = create(:device, site: site, name: "Teste Nó 2", integration: integ, address: { "host" => "192.168.0.21" }, firmware: "1.2")
        create(:point, site: site, device: dev, name: "Teste Relé", key: "rele")
      end
      get "/integracoes/#{integ.id}/diagnostico"
      expect(response.headers["Content-Disposition"]).to include("diagnostico-zwave_js-")
      body = response.body
      data = JSON.parse(body)
      expect(data.dig("plugin", "key")).to eq("zwave_js")
      expect(data["devices"].first).to include("name" => "Teste Nó 2", "firmware" => "1.2", "address" => { "host" => "oculto" })
      expect(data["devices"].first["points"].first["key"]).to eq("rele")
      expect(body).not_to include("192.168.0.2", "segredo", "cred-secreta", "ana@exemplo")
    end

    it "logs: agrupa, filtra por nível e fonte, baixa e limpa; o completo vem do supervisor" do
      3.times { |n| SystemLog.record!("warn", "[tuya] sem resposta em #{n} s") }
      SystemLog.record!("error", "Falhou geral")
      expect(SystemLog.count).to eq(2)
      expect(SystemLog.find_by(source: "tuya").count).to eq(3)

      get "/configuracoes/logs"
      expect(response.body).to include("sem resposta em 2 s", "3 vezes", "Falhou geral")
      get "/configuracoes/logs", params: { nivel: "error" }
      expect(response.body).to include("Falhou geral").and(not_include("sem resposta"))
      get "/configuracoes/logs", params: { fonte: "tuya", q: "resposta" }
      expect(response.body).to include("sem resposta").and(not_include("Falhou geral"))
      get "/configuracoes/logs.text", params: { fonte: "tuya" }
      expect(response.body).to match(/WARN \[tuya\] \(3x\) \[tuya\] sem resposta/)

      get "/configuracoes/logs", params: { aba: "completo" }
      expect(response.body).to include("só roda no servidor local")
      allow(Apps::Supervisor).to receive(:configured?).and_return(true)
      allow(Apps::Supervisor).to receive(:request).with(:get, "/system/logs?service=worker&lines=500").and_return("data" => { "lines" => "a ok
b [tuya] falha
" })
      get "/configuracoes/logs", params: { aba: "completo", servico: "worker", q: "tuya" }
      expect(response.body).to include("b [tuya] falha").and(not_include("a ok"))

      delete "/configuracoes/logs"
      expect(SystemLog.count).to eq(0)
    end

    it "o Sink passa só aviso ou pior, numa thread" do
      sink = SystemLog::Sink.new
      sink.info("[x] nada")
      sink.warn("[mqtt] caiu")
      sink.error(RuntimeError.new("boom"))
      20.times { break if SystemLog.count == 2; sleep 0.05 }
      expect(SystemLog.pluck(:source, :level)).to contain_exactly(%w[mqtt warn], %w[core error])
    end

    it "logs não aparecem para quem não é dono nem com mais de uma instalação" do
      create(:user)
      get "/configuracoes/logs"
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "A16 duas etapas (TOTP) e passkeys" do
    def totp_now(secret) = Mfa::Totp.code(secret, Time.now.to_i / 30)

    it "TOTP segue a RFC 6238 e a base32" do
      secret = Mfa::Totp.base32("12345678901234567890")
      expect(secret).to eq("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ")
      expect(Mfa::Totp.code(secret, 59 / 30)).to eq("287082")
      expect(Mfa::Totp.unbase32(secret)).to eq("12345678901234567890")
      expect(Mfa::Totp.uri(secret, "a@b.c")).to start_with("otpauth://totp/Minha%20Automa%C3%A7%C3%A3o%3Aa%40b.c?secret=GEZD")
    end

    it "liga pelo QR, pede o código no login (web e API), aceita recuperação uma vez e desliga" do
      sign_in
      get "/configuracoes/seguranca"
      secret = response.body[/<code[^>]*>([A-Z2-7 ]+)<\/code>/, 1].delete(" ")
      post "/configuracoes/seguranca/totp", params: { code: "000000" }
      expect(flash[:alert]).to eq("Código inválido.")
      post "/configuracoes/seguranca/totp", params: { code: totp_now(secret) }
      follow_redirect!
      codes = response.body.scan(/<li class="ss-code-inline[^>]*>([a-z0-9-]{11})<\/li>/).flatten
      expect(codes.size).to eq(10)
      expect(user.reload.otp_enabled_at).to be_present

      delete "/sair"
      sign_in
      expect(response).to redirect_to("/entrar/codigo")
      get "/"
      expect(response).to redirect_to(%r{/entrar})
      post "/entrar/codigo", params: { code: "123456" }
      expect(response).to have_http_status(:unprocessable_content)
      post "/entrar/codigo", params: { code: totp_now(secret) }
      expect(response).to redirect_to("/")
      delete "/sair"
      sign_in
      post "/entrar/codigo", params: { code: totp_now(secret) }
      expect(response).to have_http_status(:unprocessable_content) # o mesmo código não vale de novo
      post "/entrar/codigo", params: { code: codes.first }
      expect(response).to redirect_to("/")
      expect(user.reload.otp_recovery.size).to eq(9)

      post "/api/v1/auth/login", params: { email: user.email, password: "12345678" }
      expect(response.parsed_body.dig("error", "code")).to eq("mfa_required")
      post "/api/v1/auth/login", params: { email: user.email, password: "12345678", otp: codes.first }
      expect(response.parsed_body.dig("error", "code")).to eq("invalid_otp")
      post "/api/v1/auth/login", params: { email: user.email, password: "12345678", otp: codes.second }
      expect(response).to have_http_status(:created)

      delete "/configuracoes/seguranca/totp", params: { code: codes.third }
      expect(user.reload.otp_enabled_at).to be_nil
      expect(Mfa.required?(user)).to be(false)
    end

    it "fator de MFA de plugin falso entra sem mudar o núcleo" do
      fake = Module.new do
        def self.enabled?(u) = u.name.start_with?("Teste")
        def self.verify!(_u, code) = code == "424242"
      end
      stub_const("Mfa::TesteSms", fake)
      stub_const("Mfa::FACTORS", Mfa::FACTORS + [ "TesteSms" ])
      user.update!(name: "Teste Ana")
      sign_in
      expect(response).to redirect_to("/entrar/codigo")
      post "/entrar/codigo", params: { code: "424242" }
      expect(response).to redirect_to("/")
    end

    it "passkey: cadastra logado e entra sem senha; assinatura errada ou contador repetido não entram" do
      key = OpenSSL::PKey::EC.generate("prime256v1")
      rp = "www.example.com"
      auth = ->(count) { Digest::SHA256.digest(rp) + [ 0x05 ].pack("C") + [ count ].pack("N") }
      client = ->(type, ch) { { type: type, challenge: ch, origin: "http://#{rp}" }.to_json }
      b = ->(x) { Passkeys.b64(x) }

      sign_in
      get "/configuracoes/seguranca/passkeys/opcoes"
      opts = response.parsed_body
      expect(opts.dig("rp", "id")).to eq(rp)
      post "/configuracoes/seguranca/passkeys", as: :json, params: { id: "cred-1", name: "Teste Chave", clientDataJSON: b.(client.("webauthn.create", opts["challenge"])),
                                                                     authenticatorData: b.(auth.(0)), publicKey: b.(key.public_to_der) }
      expect(response.parsed_body["redirect"]).to eq("/configuracoes/seguranca")
      expect(user.passkeys.pluck(:name)).to eq([ "Teste Chave" ])

      delete "/sair"
      login = lambda do |count, signer = key|
        get "/entrar/passkey"
        cd = client.("webauthn.get", response.parsed_body["challenge"])
        ad = auth.(count)
        post "/entrar/passkey", as: :json, params: { id: "cred-1", clientDataJSON: b.(cd), authenticatorData: b.(ad),
                                                     signature: b.(signer.sign("SHA256", ad + Digest::SHA256.digest(cd))) }
      end
      login.(1, OpenSSL::PKey::EC.generate("prime256v1"))
      expect(response).to have_http_status(:unauthorized)
      login.(1)
      expect(response.parsed_body["redirect"]).to eq("/")
      get "/configuracoes/seguranca"
      expect(response.body).to include("Teste Chave", "usada")
      delete "/sair"
      login.(1)
      expect(response).to have_http_status(:unauthorized)

      sign_in
      delete "/configuracoes/seguranca/passkeys/#{user.passkeys.first.id}"
      expect(user.passkeys.count).to eq(0)
    end
  end

  describe "A15 restaurar backup pela tela e na primeira configuração" do
    let(:dir) { Dir.mktmpdir }
    let(:dump) { "-- PostgreSQL database dump\nCREATE TABLE teste ();\n" }

    def gz(text) = StringIO.new(ActiveSupport::Gzip.compress(text))
    def upload(io, name) = Rack::Test::UploadedFile.new(io, "application/gzip", true, original_filename: name)

    before do
      stub_const("ENV", ENV.to_h.merge("BACKUP_DIR" => dir))
      allow(Backups::Restore).to receive(:dir).and_return(File.join(dir, "restore"))
      File.binwrite(File.join(dir, "minha_automacao-20261101.sql.gz"), ActiveSupport::Gzip.compress(dump))
      allow(Apps::Supervisor).to receive(:configured?).and_return(true)
    end

    after { FileUtils.rm_rf(dir) }

    it "abre e confere o arquivo: .sql.gz, .enc com senha, senha errada e arquivo que não é dump" do
      expect(Backups::Restore.upload!(gz(dump))).to match(/\Arestaurar-\d{8}-\d{6}\.sql\.gz\z/)
      enc = StringIO.new.binmode
      Backups.encrypt(gz(dump), enc, "senha-boa")
      enc.rewind
      name = Backups::Restore.upload!(enc, passphrase: "senha-boa")
      expect(ActiveSupport::Gzip.decompress(File.binread(File.join(dir, "restore", name)))).to eq(dump)
      enc.rewind
      expect { Backups::Restore.upload!(enc, passphrase: "errada") }.to raise_error(Backups::Error, "Senha do backup errada ou arquivo corrompido.")
      expect { Backups::Restore.upload!(gz("oi")) }.to raise_error(Backups::Error, /não é um backup/)
      expect { Backups::Restore.upload!(StringIO.new("texto")) }.to raise_error(Backups::Error, /não é um backup/)
    end

    it "dono lista, confirma com a palavra e o supervisor restaura; enviado vai como storage" do
      sign_in
      get "/configuracoes/backups"
      expect(response.body).to include("minha_automacao-20261101.sql.gz", "Digite RESTAURAR para confirmar")
      post "/configuracoes/backups", params: { pick: "local:minha_automacao-20261101.sql.gz", confirm: "não" }
      expect(flash[:alert]).to include("palavra de confirmação")
      expect(Apps::Supervisor).to receive(:request).with(:post, "/system/restore", { file: "minha_automacao-20261101.sql.gz", source: "backups" }).and_return({})
      post "/configuracoes/backups", params: { pick: "local:minha_automacao-20261101.sql.gz", confirm: "restaurar" }
      expect(flash[:notice]).to include("Restauração começou")
      expect(within(tenant) { AuditEvent.where(action: "backup.restore").count }).to eq(1)
      post "/configuracoes/backups", params: { pick: "local:../../etc/passwd", confirm: "RESTAURAR" }
      expect(flash[:alert]).to eq("Backup inválido.")

      expect(Apps::Supervisor).to receive(:request).with(:post, "/system/restore", hash_including(source: "storage")).and_return({})
      post "/configuracoes/backups", params: { file: upload(gz(dump), "casa.sql.gz"), confirm: "RESTAURAR" }
      expect(flash[:notice]).to include("Restauração começou")

      File.write(File.join(dir, "restore-status.json"), { state: "running", step: "restore", file: "x.sql.gz" }.to_json)
      get "/configuracoes/backups"
      expect(response.body).to include("Restaurando · restaurando")
      post "/configuracoes/backups", params: { pick: "local:minha_automacao-20261101.sql.gz", confirm: "RESTAURAR" }
      expect(flash[:alert]).to eq("Já existe uma restauração em andamento.")
    end

    it "instalação nova restaura antes de criar conta; depois o passo some" do
      User.delete_all
      get "/primeira-configuracao"
      expect(response.body).to include("Já tem um backup? Restaure aqui")
      get "/primeira-configuracao/restore"
      expect(response.body).to include("Restaurar de um backup", "Começar do zero")
      post "/primeira-configuracao/restore", params: { onboarding: {} }
      expect(response.body).to include("Escolha o arquivo de backup.")
      expect(Apps::Supervisor).to receive(:request).with(:post, "/system/restore", hash_including(source: "storage")).and_return({})
      post "/primeira-configuracao/restore", params: { onboarding: { file: upload(gz(dump), "casa.sql.gz") } }
      expect(response).to redirect_to("/primeira-configuracao/restore")
    end

    it "não aparece para admin nem com mais de uma instalação" do
      sign_in(within(tenant) { create(:user, tenant: tenant, role: "admin") })
      get "/configuracoes/backups"
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "A18 firmware dos aparelhos (entidade update)" do
    before { sign_in }

    it "provedor falso: confere, mostra em Sistema e instala com auditoria" do
      calls = []
      fake = Class.new(Firmware::Provider) do
        describe key: "teste"
        define_singleton_method(:handles?) { |d| d.driver == "virtual" }
        define_singleton_method(:check) { |_d| { installed: "1.0", latest: "1.1", notes_url: "https://exemplo.com/notas" } }
        define_singleton_method(:install!) { |d| calls << d.name }
      end
      stub_const("Firmware::Providers::Teste", fake)
      stub_const("Firmware::PROVIDERS", Firmware::PROVIDERS + [ "Teste" ])
      device # existe antes da verificação diária
      FirmwareCheckJob.perform_now
      point = within(tenant) { device.points.find_by!(capability: "update") }
      expect(point).to have_attributes(capability: "update", data_type: "json")
      expect(Firmware.view(point.value)).to include(installed: "1.0", latest: "1.1", state: "available")
      expect(within(tenant) { Firmware.check!(device) }.id).to eq(point.id)

      get "/configuracoes/sistema"
      expect(response.body).to include("Firmware dos aparelhos", "Medidor", "instalada 1.0 · mais nova 1.1", "novidades", "Instalar")
      post "/configuracoes/sistema/firmware/#{point.id}"
      expect(flash[:notice]).to eq("Medidor: atualização enviada ao aparelho.")
      expect(calls).to eq([ "Medidor" ])
      expect(Firmware.view(point.reload.value)[:state]).to eq("installing")
      expect(within(tenant) { AuditEvent.where(action: "firmware.install").count }).to eq(1)
      get "/configuracoes/sistema"
      expect(response.body).to include("Instalando")
    end

    it "Shelly Gen2 pelo RPC e Zigbee2MQTT pelo pedido da ponte" do
      shelly = within(tenant) { create(:device, site: site, name: "Teste Shelly", driver: "shelly", address: { "host" => "192.168.0.30", "gen" => 2 }) }
      stub_request(:post, "http://192.168.0.30/rpc").with(body: hash_including("method" => "Shelly.GetDeviceInfo")).to_return(body: { result: { ver: "1.4.2" } }.to_json)
      stub_request(:post, "http://192.168.0.30/rpc").with(body: hash_including("method" => "Shelly.CheckForUpdate")).to_return(body: { result: { stable: { version: "1.4.4" } } }.to_json)
      upd = stub_request(:post, "http://192.168.0.30/rpc").with(body: hash_including("method" => "Shelly.Update")).to_return(body: { result: nil }.to_json)
      point = within(tenant) { Firmware.check!(shelly) }
      expect(Firmware.view(point.value)).to include(installed: "1.4.2", latest: "1.4.4", state: "available")
      within(tenant) { Firmware.install!(point, user: user) }
      expect(upd).to have_been_requested

      z = within(tenant) { create(:device, site: site, name: "Teste Sensor", driver: "mqtt", external_id: "0x00158d0001") }
      zp = within(tenant) { Firmware.ensure_point!(z, address: { "topic" => "zigbee2mqtt/Teste Sensor", "json_path" => "update" }) }
      zp.update!(value: { "state" => "available", "installed_version" => 16, "latest_version" => 20 })
      expect(Firmware.view(zp.value)).to include(installed: "16", latest: "20", state: "available")
      expect(Mqtt::Listener).to receive(:publish).with("zigbee2mqtt/bridge/request/device/ota_update/update", { id: "0x00158d0001" }.to_json)
      within(tenant) { Firmware.install!(zp.reload, user: user) }
      expect(Firmware.view({ "state" => "updating" })[:state]).to eq("installing")
      expect(within(tenant) { Firmware.check!(z) }).to be_nil
    end
  end

  describe "A20 cards de terceiros com hash e isolamento" do
    let(:js) { "customElements.define('teste-card', class extends HTMLElement { set hass(h) { this.textContent = h.states['luz'].state } })" }
    let(:sha) { Digest::SHA256.hexdigest(js) }
    let(:dir) { Dir.mktmpdir }
    let(:manifest) do
      { "format" => 1, "key" => "teste-cards", "name" => "Teste Cards", "version" => "1.0.0",
        "items" => [ { "type" => "card", "key" => "teste", "name" => "Teste Card", "url" => "https://cdn.exemplo.com/teste-card.js", "sha256" => sha, "element" => "teste-card" } ] }
    end
    let!(:lamp) { within(tenant) { create(:point, site: site, device: device, name: "Teste Luz", key: "luz", value: true) } }

    before do
      allow(Cards).to receive(:dir).and_return(dir)
      allow(SafeHttp).to receive(:check!).and_return("203.0.113.7")
      stub_request(:get, "https://cdn.exemplo.com/teste-card.js").to_return(body: js)
    end

    after { FileUtils.rm_rf(dir) }

    it "instala conferindo o hash, serve pelo hash sem login e recusa arquivo trocado" do
      bad = manifest.deep_dup.tap { |m| m["items"][0]["sha256"] = "0" * 64 }
      expect { within(tenant) { Packages.install!(site, bad, "https://cdn.exemplo.com/x.json") } }.to raise_error(Packages::Error, /não bate com o sha256/)
      expect(within(tenant) { Packages.errors(manifest.deep_merge("items" => [ { "type" => "card", "key" => "xx", "url" => "http://a/b.js", "sha256" => "x", "element" => "x" } ]), site) })
        .to include(a_string_matching(/https/), a_string_matching(/sha256/), a_string_matching(/element/))

      within(tenant) { Packages.install!(site, manifest.deep_merge("items" => [ manifest["items"][0].merge("sha256" => Cards.integrity(sha)) ]), "https://cdn.exemplo.com/x.json") }
      expect(within(tenant) { Cards.available(site) }).to eq([ { "ref" => "teste-cards/teste", "name" => "Teste Card", "sha" => sha, "element" => "teste-card" } ])
      get "/cartoes/#{sha}.js"
      expect(response.body).to eq(js)
      expect(response.headers).to include("Access-Control-Allow-Origin" => "*", "X-Content-Type-Options" => "nosniff")
      File.write(File.join(dir, "#{sha}.js"), "alert(1)")
      get "/cartoes/#{sha}.js"
      expect(response).to have_http_status(:not_found)
    end

    it "widget roda o card num iframe sandbox com integrity e o estado no formato do HA" do
      within(tenant) { Packages.install!(site, manifest, "https://cdn.exemplo.com/x.json") }
      r = Struct.new(:site, :used) { def use(p) = (used << p) && p }.new(site, [])
      w = { "type" => "custom_card", "card" => "teste-cards/teste", "config" => '{"title":"Oi"}', "height" => "300" }
      data, = within(tenant) { Dashboards::Widgets::CustomCardWidget.data(r, w, [ lamp ]) }
      expect(data["config"]).to eq("title" => "Oi", "type" => "custom:teste-card", "entities" => [ "luz" ])
      expect(data["states"]["luz"]).to include("state" => "on", "attributes" => hash_including("friendly_name" => "Teste Luz"))
      html = ApplicationController.render(partial: "web/dashboards/widgets/custom_card", locals: { w: w.merge("data" => data), points: {}, dashboard: nil, live: false })
      expect(html).to include('sandbox="allow-scripts"', "integrity=&quot;#{Cards.integrity(sha)}&quot;", "/cartoes/#{sha}.js", "height: 300px")
      expect(html).not_to include("allow-same-origin")
      expect(Dashboards::Widgets::CustomCardWidget.errors(w.merge("config" => "{x"))).to eq([ "config precisa ser um objeto JSON." ])
      missing, = within(tenant) { Dashboards::Widgets::CustomCardWidget.data(r, w.merge("card" => "nada/nada"), []) }
      expect(missing).to eq("missing" => true, "web_only" => true)
    end
  end
end
