require "rails_helper"

# Backup fora de casa no Google Drive: conectar pela tela de Saúde (OAuth do
# cliente Google da agenda, escopo drive.file), token cifrado, envio
# resumable para a pasta do app, retenção, download do teste de restauração e
# renovação do token. Nada sai para a rede: um Drive falso em memória
# responde pelo WebMock.
RSpec.describe "Backup no Google Drive" do
  let(:owner) { create(:user, email: "teste-dono@ex.com") }
  let(:tmp) { Dir.mktmpdir("gdrive") }
  let(:drive) { { files: {}, seq: 0, grants: [] } }
  let(:gd) { Backups::Destinations::GoogleDrive }

  def sign_in(u = owner) = post("/entrar", params: { email: u.email, password: "12345678" })

  before do
    stub_const("ENV", ENV.to_h.merge("GOOGLE_CLIENT_ID" => "cid", "GOOGLE_CLIENT_SECRET" => "csec", "BACKUP_DIR" => File.join(tmp, "local"),
                                     "BACKUP_STATUS_FILE" => File.join(tmp, "status.json"), "BACKUP_PASSPHRASE" => "senha de teste",
                                     "BACKUP_OFFSITE_KEEP" => "2"))
    stub_request(:post, "https://oauth2.googleapis.com/token").to_return { |req| token_answer(Rack::Utils.parse_query(req.body)) }
    stub_request(:any, %r{\Ahttps://www\.googleapis\.com/}).to_return { |req| drive_answer(req) }
  end

  after { FileUtils.rm_rf(tmp) }

  # --- Google falso ---

  def token_answer(form)
    drive[:grants] << form["grant_type"]
    return { status: 400, body: { error: "invalid_grant", error_description: "Token has been expired or revoked." }.to_json } if drive[:revoked]

    body = { access_token: "A#{drive[:grants].size}", expires_in: 3600 }
    body[:refresh_token] = "R1" if form["grant_type"] == "authorization_code" && form["code"] == "C1"
    { status: 200, body: body.to_json }
  end

  def drive_answer(req)
    return { status: 401 } unless req.headers["Authorization"].to_s.start_with?("Bearer A")

    q = Rack::Utils.parse_query(req.uri.query)
    files = drive[:files]
    path = req.uri.path
    case [ req.method, path ]
    in [ :get, "/drive/v3/about" ] then ok(user: { emailAddress: "teste@exemplo.com" })
    in [ :get, "/drive/v3/files" ]
      found = if q["q"].include?("mimeType") then files.select { |_, f| f[:folder] && q["q"].include?("name = '#{f[:name]}'") }
      else files.select { |_, f| q["q"].include?("'#{f[:parent]}' in parents") }
      end
      ok(files: found.map { |id, f| { id: id, name: f[:name], size: f[:body].to_s.bytesize.to_s } })
    in [ :post, "/drive/v3/files" ]
      ok(id: add(JSON.parse(req.body).then { |m| { name: m["name"], folder: m["mimeType"].end_with?("folder") } }))
    in [ :post, "/upload/drive/v3/files" ]
      m = JSON.parse(req.body)
      id = add(name: m["name"], parent: m["parents"].first, pending: true)
      { status: 200, headers: { "Location" => "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&upload_id=#{id}" } }
    in [ :put, "/upload/drive/v3/files" ]
      files[q["upload_id"]].merge!(body: req.body.b, pending: false)
      ok(id: q["upload_id"])
    in [ :delete, %r{\A/drive/v3/files/} ] then files.delete(path.split("/").last) ? { status: 204 } : { status: 404 }
    in [ :get, %r{\A/drive/v3/files/} ] if q["alt"] == "media" then { status: 200, body: files.fetch(path.split("/").last)[:body] }
    end
  end

  def ok(body) = { status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" } }
  def add(file) = (drive[:seq] += 1).to_s.then { |id| drive[:files][id] = file and id }
  def copies = drive[:files].values.reject { |f| f[:folder] }.map { |f| f[:name] }.sort

  def dump!(name, sql)
    FileUtils.mkdir_p(File.join(tmp, "local"))
    path = File.join(tmp, "local", name)
    Zlib::GzipWriter.open(path) { |gz| gz.write(sql) }
    at = Time.now - 100 + (Dir.children(File.dirname(path)).size * 10) # cada dump é o mais novo
    File.utime(at, at, path)
  end

  it "conecta pela tela de Saúde (consentimento offline), guarda o token cifrado e desconecta revogando" do
    sign_in
    get "/configuracoes/saude"
    href = CGI.unescapeHTML(response.body[/href="(https:\/\/accounts\.google\.com[^"]+)"/, 1])
    query = Rack::Utils.parse_query(URI(href).query)
    expect(query).to include("scope" => gd::SCOPE, "access_type" => "offline", "prompt" => "consent", "client_id" => "cid",
                             "redirect_uri" => "http://www.example.com/integracoes/oauth/retorno")
    expect(response.body).to include("Conectar Google Drive")

    get "/integracoes/oauth/retorno", params: { state: query["state"], error: "access_denied" }
    expect(flash[:alert]).to include("cancelada")
    expect(gd).not_to be_connected

    get "/integracoes/oauth/retorno", params: { state: query["state"], code: "C1" }
    expect(response).to redirect_to("/configuracoes/saude")
    expect(gd).to be_connected
    expect(File.read(gd.file)).not_to include("R1") # cifrado
    expect(gd.secrets).to include("refresh_token" => "R1", "email" => "teste@exemplo.com")
    expect(Backups.url).to eq(gd::URL)
    expect(Backups.destination).to be_a(gd)

    follow_redirect!
    expect(response.body).to include("Conectado como teste@exemplo.com", "Desconectar", "Minha Automação – Backups")

    revoke = stub_request(:post, gd::REVOKE).with(body: { "token" => "R1" })
    delete "/configuracoes/saude/google-drive"
    expect(revoke).to have_been_requested
    expect(gd).not_to be_connected
    expect(Backups.url).to be_nil
  end

  it "sem refresh token não conecta; outra instalação nem vê o botão nem usa o retorno" do
    sign_in
    state = Integrations.oauth_state(gd.state_for(owner))
    get "/integracoes/oauth/retorno", params: { state: state, code: "SEM-REFRESH" }
    expect(flash[:alert]).to include("autorização permanente")
    expect(gd).not_to be_connected

    other = create(:user, email: "teste-outro@ex.com")
    sign_in(other)
    get "/configuracoes/saude"
    expect(response.body).not_to include("Conectar Google Drive")
    get "/integracoes/oauth/retorno", params: { state: state, code: "C1" }
    expect(response).to have_http_status(:not_found)
    delete "/configuracoes/saude/google-drive"
    expect(response).to have_http_status(:not_found)
    expect(gd).not_to be_connected
  end

  it "manda cifrado para a pasta do app, guarda só as mais novas, restaura baixando do Drive e renova o token vencido" do
    gd.connect!("C1", "https://casa/integracoes/oauth/retorno")
    dump!("minha_automacao-2026-10-29.sql.gz", "a")
    Backups.offsite!
    dump!("minha_automacao-2026-10-30.sql.gz", "b")
    Backups.offsite!
    Backups.offsite!(force: true) # reenvio troca o de mesmo nome, não duplica
    live = Backups.live_counts
    dump!("minha_automacao-2026-10-31.sql.gz", Backups::TABLES.map { |t| "CREATE TABLE #{t} (id int);\nINSERT INTO #{t} SELECT generate_series(1, #{live[t]});\n" }.join)
    Backups.offsite!

    folders = drive[:files].values.select { |f| f[:folder] }
    expect(folders.map { |f| f[:name] }).to eq([ "Minha Automação – Backups" ])
    expect(copies).to eq(%w[minha_automacao-2026-10-30.sql.gz.enc minha_automacao-2026-10-31.sql.gz.enc])
    expect(drive[:files].values.reject { |f| f[:folder] }.map { |f| f[:body] }).to all(start_with("Salted__".b))
    expect(Backups.status).to include("file" => "minha_automacao-2026-10-31.sql.gz.enc", "removed" => 1, "error" => nil)
    expect(Backups.status["destination"]).to match(/\AGoogle Drive: teste@exemplo\.com · 2 cópia\(s\), \d+ \w+\z/)
    expect(drive[:grants]).to eq(%w[authorization_code]) # access token ainda valia

    gd.merge_secrets!("expires_at" => 0)
    Backups.restore_test!
    expect(Backups.status["restore_error"]).to be_nil
    expect(Backups.status["restore_counts"]).to eq(live)
    expect(drive[:grants]).to eq(%w[authorization_code refresh_token])
    expect(gd.secrets).to include("access_token" => "A2", "refresh_token" => "R1")
  end

  it "token revogado no Google vira erro do backup na tela, não exceção" do
    gd.connect!("C1", "https://casa/integracoes/oauth/retorno")
    gd.merge_secrets!("expires_at" => 0)
    drive[:revoked] = true
    dump!("minha_automacao-2026-11-01.sql.gz", "a")
    expect(Backups.offsite!).to be_nil
    expect(Backups.status["error"]).to include("expired or revoked")
    item = Health.run(owner.tenant, only: "backup").first.items.find { |i| i.key == "offsite" }
    expect(item.status).to eq("error")
  end
end
