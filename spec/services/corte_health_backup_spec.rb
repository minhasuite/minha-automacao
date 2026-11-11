require "rails_helper"

# Corte (cutover): saúde do sistema como registro, backup fora de casa
# cifrado com destino plugável e teste de restauração, e as pré-checagens da
# troca. Nada sai para a rede: o destino dos specs é uma pasta local.
RSpec.describe "Corte: saúde, backup externo e troca" do
  let(:tenant) { create(:tenant) }
  let(:site) { within(tenant) { create(:site, name: "Teste Casa") } }
  let(:tmp) { Dir.mktmpdir("corte") }
  let(:remote) { File.join(tmp, "remoto") }

  # Destino falso: só existe no spec e entra pelo registro, sem mudar o núcleo.
  let(:fake_destination) do
    Class.new do
      def self.owns?(uri) = uri.scheme == "pasta"
      def self.label = "Pasta"
      def initialize(uri) = (@dir = uri.path)
      def describe = "Pasta #{@dir}"
      def upload(path, name) = FileUtils.mkdir_p(@dir).then { FileUtils.cp(path, File.join(@dir, name)) }
      def list = Dir.children(@dir)
      def delete(name) = File.delete(File.join(@dir, name))
      def download(name, path) = FileUtils.cp(File.join(@dir, name), path)
    end
  end

  def env(extra = {})
    ENV.to_h.merge("BACKUP_DIR" => File.join(tmp, "local"), "BACKUP_STATUS_FILE" => File.join(tmp, "status.json"),
                   "BACKUP_OFFSITE_URL" => "pasta://x#{remote}", "BACKUP_PASSPHRASE" => "senha de teste", "BACKUP_OFFSITE_KEEP" => "2").merge(extra)
  end

  def dump!(name, sql, mtime: Time.current)
    FileUtils.mkdir_p(File.join(tmp, "local"))
    path = File.join(tmp, "local", name)
    Zlib::GzipWriter.open(path) { |gz| gz.write(sql) }
    File.utime(mtime.to_time, mtime.to_time, path)
    path
  end

  before do
    stub_const("Backups::Destinations::Pasta", fake_destination)
    stub_const("Backups::DESTINATIONS", Backups::DESTINATIONS + %w[Pasta])
    stub_const("ENV", env)
  end

  after { FileUtils.rm_rf(tmp) }

  describe "cifra" do
    it "ida e volta com a senha; senha errada não abre" do
      out = StringIO.new("".b)
      Backups.encrypt(StringIO.new("dados do banco" * 1000), out)
      expect(out.string).to start_with("Salted__")
      back = StringIO.new("".b)
      Backups.decrypt(StringIO.new(out.string), back)
      expect(back.string).to eq("dados do banco" * 1000)
      expect { Backups.decrypt(StringIO.new(out.string), StringIO.new, "outra") }.to raise_error(Backups::Error, /senha/)
    end

    it "abre com o openssl comum (sem o app)" do
      skip "sem openssl no PATH" unless system("which openssl > /dev/null 2>&1")
      enc = File.join(tmp, "x.enc")
      File.open(enc, "wb") { |o| Backups.encrypt(StringIO.new("abre fora"), o) }
      out, st = Open3.capture2({ "P" => "senha de teste" }, "openssl", "enc", "-d", "-aes-256-cbc", "-pbkdf2", "-iter", "200000", "-md", "sha256",
                               "-in", enc, "-pass", "env:P")
      expect([ st.success?, out ]).to eq([ true, "abre fora" ])
    end
  end

  describe "cópia fora de casa" do
    it "manda o dump mais novo cifrado pelo destino do registro, não repete e guarda só as mais novas" do
      dump!("minha_automacao-2026-10-29.sql.gz", "a", mtime: 3.days.ago)
      dump!("minha_automacao-2026-10-30.sql.gz", "b", mtime: 2.days.ago)
      FileUtils.mkdir_p(remote)
      %w[minha_automacao-2026-10-28.sql.gz.enc minha_automacao-2026-10-29.sql.gz.enc].each { |n| File.write(File.join(remote, n), "x") }

      Backups.offsite!
      expect(Dir.children(remote).sort).to eq(%w[minha_automacao-2026-10-29.sql.gz.enc minha_automacao-2026-10-30.sql.gz.enc])
      expect(File.binread(File.join(remote, "minha_automacao-2026-10-30.sql.gz.enc"))).to start_with("Salted__")
      expect(Backups.status).to include("file" => "minha_automacao-2026-10-30.sql.gz.enc", "destination" => "Pasta #{remote}", "removed" => 1)
      expect(Backups.offsite_ok?).to be true

      expect(Backups).not_to receive(:destination)
      Backups.offsite! # mesmo arquivo: não manda de novo
    end

    it "falha vira estado (tela e ponto), não exceção na fila; sem configuração fica desligado" do
      expect(Backups.offsite!).to be_nil
      expect(Backups.status["error"]).to include("nenhum backup local")
      expect(Backups.offsite_ok?).to be false

      stub_const("ENV", env("BACKUP_OFFSITE_URL" => "ftp://x/y"))
      dump!("minha_automacao-2026-10-30.sql.gz", "b")
      Backups.offsite!
      expect(Backups.status["error"]).to include("destino de backup desconhecido")

      stub_const("ENV", env("BACKUP_PASSPHRASE" => ""))
      expect(Backups).not_to be_configured
      expect(BackupOffsiteJob.perform_now).to be_nil
    end

    it "teste de restauração: baixa, restaura num banco temporário e confere as contagens" do
      live = Backups.live_counts
      sql = "\\restrict abc\n" + Backups::TABLES.map { |t| "CREATE TABLE #{t} (id int);\nINSERT INTO #{t} SELECT generate_series(1, #{live[t]});\n" }.join +
            "\\unrestrict abc\n"
      dump!("minha_automacao-2026-10-31.sql.gz", sql)
      Backups.offsite!
      BackupOffsiteJob.perform_now("restore")
      expect(Backups.status["restore_error"]).to be_nil
      expect(Backups.status["restore_counts"]).to eq(live)
      expect(Backups.restore_ok?).to be true
      expect(ActiveRecord::Base.connection.select_values("SELECT datname FROM pg_database").grep(/ma_restore_/)).to be_empty

      sql2 = Backups::TABLES.map { |t| "CREATE TABLE #{t} (id int);\n" }.join + "INSERT INTO points SELECT generate_series(1, 500);\n"
      dump!("minha_automacao-2026-11-01.sql.gz", sql2, mtime: 1.minute.from_now)
      Backups.offsite!
      Backups.restore_test!
      expect(Backups.status["restore_error"]).to include("contagens diferentes", "points 500/")
      expect(Backups.restore_ok?).to be false
    end
  end

  describe "destinos que vêm com o produto (sem rede)" do
    it "SSH monta os comandos sem senha e com o nome validado" do
      dest = Backups.destination("ssh://backup@vps.exemplo:2222/srv/ma")
      calls = []
      allow(Open3).to receive(:capture3) { |*cmd| calls << cmd; [ "minha_automacao-2026-10-30.sql.gz.enc\nlixo;rm\n", "", instance_double(Process::Status, success?: true) ] }
      expect(dest.list).to eq([ "minha_automacao-2026-10-30.sql.gz.enc" ])
      dest.upload("/tmp/a.enc", "a.enc")
      expect(calls.map(&:first)).to eq(%w[ssh ssh scp ssh])
      expect(calls[2]).to include("-P", "2222", "backup@vps.exemplo:/srv/ma/a.enc.tmp")
      expect(calls.flatten).to include("BatchMode=yes", "StrictHostKeyChecking=accept-new")
      expect { dest.delete("../x") }.to raise_error(Backups::Error, /nome inválido/)
      expect(dest.describe).to eq("Servidor por SSH: vps.exemplo/srv/ma")

      allow(Open3).to receive(:capture3).and_return([ "", "Permission denied (publickey).", instance_double(Process::Status, success?: false) ])
      expect { dest.list }.to raise_error(Backups::Error, /Permission denied/)
      expect { Backups.destination("ssh://vps/x") }.to raise_error(Backups::Error, /usuário e host/)
    end

    it "S3 compatível lista, manda e apaga pelo prefixo" do
      stub_const("ENV", env("BACKUP_S3_ENDPOINT" => "https://conta.r2.exemplo", "BACKUP_S3_ACCESS_KEY_ID" => "id", "BACKUP_S3_SECRET_ACCESS_KEY" => "segredo"))
      stub_request(:get, %r{conta\.r2\.exemplo/.*list-type=2}).to_return(
        body: "<ListBucketResult><Contents><Key>casa/minha_automacao-2026-10-30.sql.gz.enc</Key></Contents><IsTruncated>false</IsTruncated></ListBucketResult>"
      )
      put = stub_request(:put, %r{conta\.r2\.exemplo/.*casa/a\.enc})
      del = stub_request(:delete, %r{conta\.r2\.exemplo/.*casa/a\.enc})
      dest = Backups.destination("s3://ma-backups/casa")
      expect(dest.list).to eq([ "minha_automacao-2026-10-30.sql.gz.enc" ])
      File.write(File.join(tmp, "a.enc"), "x")
      dest.upload(File.join(tmp, "a.enc"), "a.enc")
      dest.delete("a.enc")
      expect([ put, del ]).to all(have_been_requested)
      expect(dest.describe).to eq("Armazenamento S3: ma-backups/casa/")
    end
  end

  describe "saúde do sistema" do
    it "roda cada verificação do registro; uma verificação falsa entra sem mudar o núcleo e o erro vira aviso uma vez por dia" do
      fake = Class.new(Health::Check) do
        describe key: "falsa", label: "Verificação falsa", icon: "cog"
        def self.items(_t) = [ item(key: "a", status: "error", title: "Quebrou", detail: "Teste") ]
      end
      stub_const("Health::Checks::Falsa", fake)
      stub_const("Health::CHECKS", Health::CHECKS + %w[Falsa])
      within(tenant) do
        site
        Integration.create!(site: site, name: "Teste Conta", driver: "alexa", status: "error", last_error: "401")
      end

      results = Health.run(tenant)
      expect(results.map { |r| r.check.key }).to eq(%w[integrations devices reliability queues backup disk runtime shadow custom cutover falsa])
      expect(results.find { |r| r.check.key == "integrations" }.items.first).to have_attributes(status: "error", detail: include("401"))
      expect(results.find { |r| r.check.key == "falsa" }.status).to eq("error")

      created = Health.alert!(tenant)
      expect(created.map(&:title)).to include("Verificação falsa: Quebrou", "Integrações: Teste Conta (Teste Casa)")
      expect(created.map(&:title).grep(/Pronto para a troca/)).to be_empty # cutover só informa
      expect(Health.alert!(tenant)).to be_empty
    end

    it "verificação que levanta vira item de erro dela; fila e sombra leem o estado" do
      broken = Class.new(Health::Check) do
        describe key: "quebra", label: "Quebra", icon: "cog"
        def self.items(_t) = raise("boom")
      end
      stub_const("Health::Checks::Quebra", broken)
      stub_const("Health::CHECKS", %w[Quebra Queues Shadow])
      allow(Health::Checks::Queues).to receive(:adapter).and_return("solid_queue")
      SolidQueue::Process.create!(kind: "Worker", name: "w1", pid: 1, hostname: "h", last_heartbeat_at: Time.current)
      within(tenant) do
        ShadowReport.create!(site: site, source: "home_assistant", window_from: 1.day.ago, window_to: Time.current, summary: { "different" => 2, "same" => 5 })
      end
      r = Health.run(tenant)
      expect(r[0].items.first).to have_attributes(status: "error", detail: "boom")
      expect(r[1].items.map(&:status)).to eq(%w[ok ok ok])
      expect(r[2].items.first.detail).to include("2 divergência(s)")
      expect(Health::Item.new(key: 1, status: "ok", title: "x").key).to eq("1")
      expect([ Health::Checks::Runtime.uptime(90_061), Health::Checks::Runtime.uptime(59) ]).to eq([ "1 d 1 h 1 min", "0 min" ])
      expect { Health::Item.new(key: 1, status: "talvez", title: "x") }.to raise_error(ArgumentError)
    end

    it "backup: local atrasado e cópia externa com falha aparecem com erro; o Sistema ganha o ponto" do
      dump!("minha_automacao-2026-10-01.sql.gz", "a", mtime: 3.days.ago)
      Backups.save_status!("uploaded_at" => 3.days.ago, "error" => "sem rede", "error_at" => 1.hour.ago, "restore_error" => "x", "restore_error_at" => 1.day.ago)
      items = Health.run(tenant, only: "backup").first.items
      expect(items.map(&:status)).to eq(%w[error error error])
      expect(items[1].detail).to include("falhou: sem rede")

      within(tenant) do
        Integrations::SystemPlugin.setup(site, ActionController::Parameters.new({}))
        point = site.points.find_by!("address->>'field' = 'offsite_backup_late'")
        expect(point.value).to be true
      end
    end
  end

  describe "pré-checagens da troca" do
    it "lista o que falta e fica pronto quando tudo passa" do
      within(tenant) { site }
      expect(Cutover.ready?(tenant)).to be false
      keys = ActsAsTenant.with_tenant(tenant) { Cutover.items(tenant) }.reject { |i| i.status == "ok" }.map(&:key)
      expect(keys).to include("shadow_clean", "offsite_backup", "app_installed", "push_ok")

      within(tenant) do
        (0..8).each { |d| ShadowReport.create!(site: site, source: "home_assistant", window_from: (d + 1).days.ago, window_to: d.days.ago, summary: { "same" => 3 }, created_at: d.days.ago) }
        create(:device, site: site, driver: "mobile_app", name: "Teste Celular")
      end
      DeviceToken.create!(user: create(:user, tenant: tenant, role: "owner", email: "teste-dono@ex.com"), token: "t", last_seen_at: Time.current)
      dump!("minha_automacao-2026-11-01.sql.gz", "a")
      Backups.save_status!("uploaded_at" => Time.current, "restored_at" => Time.current)
      expect(ActsAsTenant.with_tenant(tenant) { Cutover.items(tenant) }.map(&:status).uniq).to eq(%w[ok])
      expect(Cutover.ready?(tenant)).to be true

      within(tenant) { ShadowReport.create!(site: site, source: "home_assistant", window_from: 1.day.ago, window_to: Time.current, summary: { "missing" => 1 }) }
      expect(within(tenant) { Cutover.shadow_clean }).to eq([ false, "1 comparação(ões) com divergência nos últimos 7 dias" ])
    end
  end
end
