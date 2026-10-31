require "rails_helper"

# Pacote 4: Telegram, WhatsApp (API oficial) e gateway HTTP como canais do
# aviso, todos pelo canal genérico `messenger:<integração>`. Nada sai para a
# rede: WebMock em tudo.
RSpec.describe "Pacote 4: canais de aviso por mensageiro" do
  let(:tenant) { create(:tenant) }
  let(:site) { create(:site) }
  let(:owner) { create(:user, tenant: tenant, role: "owner") }
  let(:tg_api) { "https://api.telegram.org/bot123:SEGREDO" }
  let(:wa_api) { "https://graph.facebook.com/v21.0" }

  around { |ex| ActsAsTenant.with_tenant(tenant) { ex.run } }

  before { allow(SafeHttp).to receive(:lookup).and_return([ "93.184.216.34" ]) }

  def ok(result) = { status: 200, body: { ok: true, result: result }.to_json, headers: { "Content-Type" => "application/json" } }
  def form(h) = ActionController::Parameters.new(h)

  def notification(**opts)
    Notification.create!(kind: "aviso", title: "Portão aberto", body: "Há 10 min", data: { "site_id" => site.id }.merge(opts.delete(:data) || {}), **opts)
  end

  describe "Telegram" do
    def telegram(chat: "42")
      Current.user = owner
      stub_request(:post, "#{tg_api}/getMe").to_return(ok("username" => "casa_bot"))
      stub_request(:post, "#{tg_api}/deleteWebhook").to_return(ok(true))
      o = Integrations::TelegramPlugin.setup(site, form(token: "123:SEGREDO"))
      i = o.integration || site.integrations.find_by!(driver: "telegram")
      i.update!(settings: i.settings.merge("chat_id" => chat)) if chat
      i.reload
    ensure
      Current.user = nil
    end

    it "conecta pelo token (cifrado), acha o chat pelo getUpdates e manda o teste" do
      i = telegram(chat: nil)
      expect(i).to have_attributes(status: "ok", account: "casa_bot")
      expect(i.secrets["token"]).to eq("123:SEGREDO")
      expect(i.read_attribute_before_type_cast(:credentials)).not_to include("SEGREDO")
      expect(i.settings["user_id"]).to eq(owner.id)

      stub_request(:post, "#{tg_api}/getUpdates").to_return(ok([ { "update_id" => 1, "message" => { "chat" => { "id" => 42, "first_name" => "Ana" } } } ]))
      expect(Integrations::TelegramPlugin.connect_locals(i, { find: "1" })[:chats]).to eq([ { "id" => "42", "name" => "Ana" } ])
      expect(Integrations::TelegramPlugin.login(i, form(chat_id: "42")).notice).to include("Telegram pronto")

      sent = stub_request(:post, "#{tg_api}/sendMessage").with(body: hash_including("chat_id" => "42", "text" => /Teste/)).to_return(ok({}))
      expect(Integrations::TelegramPlugin.login(i, form(test: "1")).notice).to eq("Mensagem de teste enviada.")
      expect(sent).to have_been_requested
    end

    it "erro do Telegram não mostra o token" do
      stub_request(:post, "#{tg_api}/getMe").to_raise(SocketError.new("falhou #{tg_api}"))
      o = Integrations::TelegramPlugin.setup(site, form(token: "123:SEGREDO"))
      expect(o.alert).not_to include("SEGREDO")
    end

    it "aviso pelo canal: texto com link, botões ligados ao aviso e foto do anexo" do
      i = telegram
      channel = "messenger:#{i.id}"
      expect(Notifier.channel_choices(site)).to include([ channel, "Telegram: Telegram" ])
      expect(Notifier.channel_label(channel)).to eq("Telegram: Telegram")

      stub_request(:post, "#{tg_api}/sendMessage").to_return(ok({}))
      n = Notifier.deliver!([ channel ], kind: "aviso", title: "Portão aberto", body: "Há 10 min",
                                         data: { "url" => "https://exemplo.com/x", "actions" => [ { "id" => "fechar", "title" => "Fechar" } ] })
      expect(a_request(:post, "#{tg_api}/sendMessage").with { |r|
        b = JSON.parse(r.body)
        b["text"] == "Portão aberto\n\nHá 10 min\n\nhttps://exemplo.com/x" && JSON.parse(b["reply_markup"])["inline_keyboard"] == [ [ { "text" => "Fechar", "callback_data" => "#{n.id}:0" } ] ]
      }).to have_been_requested

      photo = stub_request(:post, "#{tg_api}/sendPhoto").with { |r| r.headers["Content-Type"].start_with?("multipart/form-data") && r.body.include?("JPEGDATA") }.to_return(ok({}))
      Notifier.deliver!([ channel ], kind: "aviso", title: "Movimento", image: { io: StringIO.new("JPEGDATA"), filename: "q.jpg", content_type: "image/jpeg" })
      expect(photo).to have_been_requested
    end

    it "botão tocado (leitura no worker) vira a resposta do aviso, uma vez, só da conversa configurada" do
      i = telegram
      n = notification(data: { "actions" => [ { "id" => "sim", "title" => "Sim" }, { "id" => "nao", "title" => "Não" } ] })
      expect(Automations::Triggers).to receive(:event).with(site.id, "notification_action", hash_including("action" => "nao", "user_id" => owner.id)).once
      stub_request(:post, "#{tg_api}/answerCallbackQuery").to_return(ok(true))
      stub_request(:post, "#{tg_api}/editMessageReplyMarkup").to_return(ok(true))
      updates = [ { "update_id" => 7, "callback_query" => { "id" => "c1", "data" => "#{n.id}:1", "message" => { "message_id" => 9, "chat" => { "id" => 99 } } } },
                  { "update_id" => 8, "callback_query" => { "id" => "c2", "data" => "#{n.id}:1", "message" => { "message_id" => 9, "chat" => { "id" => 42 } } } },
                  { "update_id" => 9, "callback_query" => { "id" => "c3", "data" => "#{n.id}:0", "message" => { "message_id" => 9, "chat" => { "id" => 42 } } } } ]
      stub_request(:post, "#{tg_api}/getUpdates").with(body: hash_including("timeout" => 1)).to_return(ok(updates))
      Integrations::TelegramPlugin.poll!(i, timeout: 1)
      expect(n.reload.response).to include("action" => "nao", "user_id" => owner.id)
      expect(i.reload.settings["offset"]).to eq(10)
      expect(a_request(:post, "#{tg_api}/answerCallbackQuery").with(body: hash_including("text" => "Este aviso já foi respondido."))).to have_been_made
      expect(a_request(:post, "#{tg_api}/answerCallbackQuery").with(body: hash_including("callback_query_id" => "c1"))).not_to have_been_made
    end

    it "webhook: só com o cabeçalho secreto; liga pelo setWebhook" do
      i = telegram
      stub_request(:post, "#{tg_api}/getMe").to_return(ok("username" => "casa_bot"))
      stub_request(:post, "#{tg_api}/setWebhook").to_return(ok(true))
      old = ENV["APP_HOST"]
      ENV["APP_HOST"] = "casa.exemplo.com"
      Integrations::TelegramPlugin.login(i, form(webhook: "1"))
      expect(a_request(:post, "#{tg_api}/setWebhook").with(body: hash_including("url" => "https://casa.exemplo.com/mensageiros/#{i.id}"))).to have_been_requested
      expect(Integrations::TelegramPlugin.pollable.where(id: i.id)).to be_empty
      secret = i.reload.secrets["webhook_secret"]

      n = notification(data: { "actions" => [ { "id" => "sim", "title" => "Sim" } ] })
      stub_request(:post, "#{tg_api}/answerCallbackQuery").to_return(ok(true))
      stub_request(:post, "#{tg_api}/editMessageReplyMarkup").to_return(ok(true))
      upd = { "update_id" => 1, "callback_query" => { "id" => "c", "data" => "#{n.id}:0", "message" => { "message_id" => 1, "chat" => { "id" => 42 } } } }.to_json
      bad = ActionDispatch::TestRequest.create("REQUEST_METHOD" => "POST", "RAW_POST_DATA" => upd, "HTTP_X_TELEGRAM_BOT_API_SECRET_TOKEN" => "errado")
      expect(Integrations::TelegramPlugin.webhook(i, bad).first).to eq(403)
      good = ActionDispatch::TestRequest.create("REQUEST_METHOD" => "POST", "RAW_POST_DATA" => upd, "HTTP_X_TELEGRAM_BOT_API_SECRET_TOKEN" => secret)
      expect(Integrations::TelegramPlugin.webhook(i, good).first).to eq(200)
      expect(n.reload.response["action"]).to eq("sim")
    ensure
      ENV["APP_HOST"] = old
    end
  end

  describe "WhatsApp (Cloud API)" do
    def whatsapp(extra = {})
      Current.user = owner
      stub_request(:get, "#{wa_api}/555").to_return(status: 200, body: { id: "555" }.to_json)
      Integrations::WhatsappPlugin.setup(site, form({ token: "TOKEN-WA", phone_id: "555", to: "+55 85 99999-0000", app_secret: "APPSEC" }.merge(extra)))
      site.integrations.find_by!(driver: "whatsapp")
    ensure
      Current.user = nil
    end

    it "texto, foto como mídia e botões de resposta; modelo quando configurado" do
      i = whatsapp
      expect(i).to have_attributes(status: "ok", account: "+5585999990000")
      stub_request(:post, "#{wa_api}/555/messages").to_return(status: 200, body: "{}")
      msgs = -> { a_request(:post, "#{wa_api}/555/messages") }
      media = stub_request(:post, "#{wa_api}/555/media").to_return(status: 200, body: { id: "M1" }.to_json)

      expect(Integrations::WhatsappPlugin.login(i, form(test: "1")).notice).to eq("Mensagem de teste enviada.")
      expect(msgs.call.with(headers: { "Authorization" => "Bearer TOKEN-WA" }, body: hash_including("type" => "text", "to" => "5585999990000"))).to have_been_requested

      n = Notifier.deliver!([ "messenger:#{i.id}" ], kind: "aviso", title: "Porta", image: { io: StringIO.new("IMG"), filename: "q.jpg", content_type: "image/jpeg" },
                                                     data: { "actions" => [ { "id" => "ok", "title" => "Ciente de tudo isso agora" } ] })
      expect(media).to have_been_requested
      expect(msgs.call.with { |r|
        b = JSON.parse(r.body)
        b["type"] == "interactive" && b.dig("interactive", "header", "image", "id") == "M1" &&
          b.dig("interactive", "action", "buttons", 0, "reply") == { "id" => "#{n.id}:0", "title" => "Ciente de tudo is..." }
      }).to have_been_requested

      i.update!(settings: i.settings.merge("template" => "aviso_casa"))
      Notifier.deliver!([ "messenger:#{i.id}" ], kind: "aviso", title: "Fora da janela")
      expect(msgs.call.with(body: hash_including("type" => "template"))).to have_been_requested
    end

    it "webhook: verificação da Meta e resposta de botão só com a assinatura do app" do
      i = whatsapp
      verify = i.secrets["verify_token"]
      get = ActionDispatch::TestRequest.create("REQUEST_METHOD" => "GET", "QUERY_STRING" => "hub.mode=subscribe&hub.verify_token=#{verify}&hub.challenge=abc")
      expect(Integrations::WhatsappPlugin.webhook(i, get)).to eq([ 200, "abc" ])
      get2 = ActionDispatch::TestRequest.create("REQUEST_METHOD" => "GET", "QUERY_STRING" => "hub.mode=subscribe&hub.verify_token=x&hub.challenge=abc")
      expect(Integrations::WhatsappPlugin.webhook(i, get2).first).to eq(403)

      n = notification(data: { "actions" => [ { "id" => "ok", "title" => "Ok" } ] })
      body = { entry: [ { changes: [ { value: { messages: [ { from: "5585999990000", type: "interactive", interactive: { button_reply: { id: "#{n.id}:0" } } } ] } } ] } ] }.to_json
      sig = "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', 'APPSEC', body)}"
      bad = ActionDispatch::TestRequest.create("REQUEST_METHOD" => "POST", "RAW_POST_DATA" => body, "HTTP_X_HUB_SIGNATURE_256" => "sha256=00")
      expect(Integrations::WhatsappPlugin.webhook(i, bad).first).to eq(403)
      expect(n.reload.response).to be_nil
      good = ActionDispatch::TestRequest.create("REQUEST_METHOD" => "POST", "RAW_POST_DATA" => body, "HTTP_X_HUB_SIGNATURE_256" => sig)
      expect(Integrations::WhatsappPlugin.webhook(i, good).first).to eq(200)
      expect(n.reload.response).to include("action" => "ok", "user_id" => owner.id)
    end

    it "falha da Meta marca a integração com erro e não derruba os outros canais" do
      i = whatsapp
      stub_request(:post, "#{wa_api}/555/messages").to_return(status: 400, body: { error: { message: "Fora da janela de 24 h" } }.to_json)
      n = Notifier.deliver!([ "messenger:#{i.id}", "in_app" ], kind: "aviso", title: "x")
      expect(n).to be_persisted
      expect(i.reload).to have_attributes(status: "error", last_error: "Fora da janela de 24 h")
    end
  end

  describe "gateway HTTP genérico" do
    it "Evolution API e CallMeBot só por modelo, sem caso especial; tudo cifrado" do
      evo = Integrations::HttpMessengerPlugin
      expect(evo.setup(site, form(url: "https://evo.exemplo.com/message/sendText/casa", headers: "apikey: CHAVE-EVO",
                                  body: '{"number": "5585999990000", "text": {{ text | json }}}')).notice).to include("Gateway salvo")
      i = site.integrations.find_by!(driver: "http_messenger")
      expect(i.read_attribute_before_type_cast(:credentials)).not_to include("CHAVE-EVO")
      req = stub_request(:post, "https://evo.exemplo.com/message/sendText/casa")
            .with(headers: { "apikey" => "CHAVE-EVO", "Content-Type" => "application/json" }, body: { "number" => "5585999990000", "text" => "Teste do Minha Automação\n\nOs avisos chegam aqui." })
            .to_return(status: 201)
      expect(evo.login(i, form(test: "1")).notice).to eq("Mensagem de teste enviada.")
      expect(req).to have_been_requested

      evo.setup(site, form(name: "CallMeBot", method: "GET", url: "https://api.callmebot.com/whatsapp.php?phone=55&text={{ title | url_encode }}&apikey=K"))
      cmb = site.integrations.find_by!(name: "CallMeBot")
      get = stub_request(:get, "https://api.callmebot.com/whatsapp.php?phone=55&text=Port%C3%A3o+aberto&apikey=K").to_return(status: 200)
      Notifier.deliver!([ "messenger:#{cmb.id}" ], kind: "aviso", title: "Portão aberto")
      expect(get).to have_been_requested

      expect(evo.setup(site, form(url: "ftp://x")).alert).to include("endereço")
      expect(evo.setup(site, form(url: "https://x", body: "{{ text ")).alert).to include("Erro no modelo")
    end
  end

  it "aberto para extensão: mensageiro novo é só um plugin de integração com send_message" do
    sent = []
    fake = Class.new(Integrations::Plugin) do
      describe key: "pombo", title: "Pombo-correio", icon: "share", description: "Teste"
      define_singleton_method(:send_message) { |integration, n| sent << [ integration.name, n.title ] }
      define_singleton_method(:setup) { |s, _f| new_integration(s, name: "Pombo").tap(&:save!) }
    end
    stub_const("Integrations::PomboPlugin", fake)
    stub_const("Integrations::PLUGINS", Integrations::PLUGINS + %w[PomboPlugin])
    i = fake.setup(site, {})
    expect(Notifier.channel_choices(site)).to include([ "messenger:#{i.id}", "Pombo-correio: Pombo" ])
    Notifier.deliver!([ "messenger:#{i.id}" ], kind: "aviso", title: "Oi")
    expect(sent).to eq([ %w[Pombo Oi] ])
  end
end
