module Integrations
  # Interface comum de um tipo de integração. Subclasse = plugin: descreve-se
  # (`describe`), monta a integração pelo assistente (`setup`), refaz o
  # login (`login`/`connect_locals`/`logged_in?`) e varre a conta
  # (`inventory`, no formato descrito em `Integrations`). As telas usam as
  # partials `web/integrations/forms/_<key>` (assistente e Reconfigurar) e
  # `web/integrations/connect/_<key>` (passo de login com QR, se houver).
  #
  # Todo passo devolve um `Outcome`: para onde a tela vai (:found = lista de
  # encontrados, :connect = passo de login, :index, :devices ou :form =
  # formulário de novo com o erro), com a integração e o aviso.
  class Plugin
    extend PluginTexts
    translates :title, :description

    Outcome = Data.define(:to, :integration, :notice, :alert, :params) do
      def initialize(to:, integration: nil, notice: nil, alert: nil, params: {}) = super
    end

    class << self
      attr_reader :key, :icon, :driver

      def describe(key:, title:, icon:, description:, driver: key)
        @key = key
        @title = title
        @icon = icon
        @description = description
        @driver = driver
      end

      def outcome(to, **) = Outcome.new(to: to, **)

      # Assistente: formulário (params) → Outcome.
      def setup(_site, _form) = raise(NotImplementedError)

      # Reconfigurar: mesmo formulário sobre a integração que já existe.
      def login(integration, _form) = outcome(:connect, integration: integration)
      def reconfigurable? = true

      # Variáveis da tela de login (QR etc.). Erro do serviço: Integrations::Error.
      def connect_locals(_integration, _params) = {}

      # A tela de login pergunta a cada 3 s; true = logou (e a varredura já está na fila).
      def logged_in?(_integration) = false

      def inventory(_integration) = raise(NotImplementedError)

      # Plugin com varredura própria (não usa o inventário genérico).
      def custom_sync? = false

      # Retorno do OAuth (`/integracoes/oauth/retorno`, params com code e redirect_uri) → Outcome.
      def oauth_callback(integration, _params) = outcome(:connect, integration: integration, alert: I18n.t("integrations.plugin.no_oauth"))

      # Depois da varredura e da adoção: grava o estado atual nos aparelhos (padrão: nada).
      def refresh(_integration) = nil

      # Lote 9: endereço de vídeo de agora de um ponto `stream` sob demanda
      # (`address.on_demand`: câmera de nuvem cujo endereço vence); nil = sem vídeo.
      def stream_url(_point) = nil

      # integ: quadro (JPEG) de um ponto de câmera do plugin (detecção com IA:
      # o da detecção de agora); nil = o plugin não tem (o go2rtc assume).
      def snapshot(_point) = nil

      # app3: true = o `snapshot` devolve o quadro de uma detecção antiga pelo
      # `id` do valor (Frigate guarda por evento); false = só o quadro de agora.
      def event_snapshots? = false

      # A cada minuto (Integrations.tick); padrão: nada.
      def tick(_now) = nil

      # Segredo gravado no aparelho adotado (local_key, token…).
      def device_secret(_integration, entry) = entry["secret"].presence

      # Pacote 1: serviço DNS-SD que acha o aparelho na rede ("_esphomelib._tcp").
      # Com ele o assistente mostra "Procurar na rede": só lista, a pessoa escolhe.
      def mdns(service = nil)
        @mdns = service if service
        @mdns
      end

      # Encontrados na rede → [{"name", "host", "port", "txt"}] (padrão: mDNS do `mdns`,
      # SSDP do `ssdp` e, pelo host, vizinhos do `dhcp` e portas do `usb`; um por endereço).
      def discover
        list = (mdns ? Mdns.browse(mdns) : []) + (ssdp ? Ssdp.search(ssdp) : []) + Host.dhcp(dhcp) + Host.usb(usb) + Ble::Discovery.matching(bluetooth)
        list.uniq { |e| e["host"] || e.dig("txt", "path") || e.dig("txt", "mac") }
      end

      # Mostra "Procurar na rede": plugin com `mdns`, `ssdp`, `dhcp`, `usb` ou com descoberta própria (Broadlink: hello UDP).
      def discovers? = mdns.present? || ssdp.present? || dhcp.any? || usb.any? || bluetooth.any?

      # ondaA2 A19: como o `dhcp` do manifesto do HA, casamentos com o vizinho
      # da rede: `dhcp({ hostname: "shelly*" }, { mac: "A4CF12" })` (glob no nome
      # que o roteador deu, prefixo do MAC).
      def dhcp(*matchers) = matchers.empty? ? (@dhcp || []) : (@dhcp = matchers)

      # E o `usb`: porta serial do host por `{ vid:, pid:, description: "*zigbee*" }`.
      def usb(*matchers) = matchers.empty? ? (@usb || []) : (@usb = matchers)

      # resto (7.23): e o `bluetooth`: anúncio por `{ local_name: "WoHand*" }`, `{ manufacturer_id: 2409 }` ou `{ service_uuid: 0xFD3D }`.
      def bluetooth(*matchers) = matchers.empty? ? (@bluetooth || []) : (@bluetooth = matchers)

      # Produto: tipo SSDP/UPnP que acha o aparelho (TVs: "urn:lge-com:service:webos-second-screen:1").
      def ssdp(st = nil)
        @ssdp = st if st
        @ssdp
      end

      # ondaA2 A12: diagnóstico para baixar (o "Baixar diagnóstico" do HA):
      # integração, aparelhos e pontos, nunca a credencial, e endereço, token,
      # IP, MAC e URL trocados por "oculto" (Sensitive.mask). O plugin junta o
      # que for dele em `diagnostics_extra` (saneado do mesmo jeito).
      def diagnostics(integration)
        devices = integration.devices.where(removed_at: nil).includes(:points).order(:name)
        data = {
          "generated_at" => Time.current.iso8601, "version" => Updates.current_tag, "plugin" => { "key" => key, "title" => title },
          "integration" => integration.slice(:driver, :name, :status, :last_error, :poll_s).merge(
            "last_ok_at" => integration.last_ok_at&.iso8601, "polled_at" => integration.polled_at&.iso8601, "settings" => integration.settings
          ),
          "devices" => devices.map do |d|
            d.slice(:name, :manufacturer, :model, :firmware, :status, :driver, :last_error, :address).merge(
              "last_seen_at" => d.last_seen_at&.iso8601,
              "points" => d.points.sort_by(&:key).map { |p| p.slice(:key, :capability, :data_type, :value, :quality, :unit, :writable, :disabled, :attrs) }
            )
          end,
          "extra" => diagnostics_extra(integration)
        }
        # E-mail da conta também sai (o JSON não tem aspas nem barra dentro do e-mail).
        JSON.parse(JSON.generate(Sensitive.mask(data.deep_stringify_keys)).gsub(/[\w.+-]+@[\w-]+(?:\.[\w-]+)+/, Sensitive::MASK))
      end

      def diagnostics_extra(_integration) = {}

      # resto (7.7): linha no log de depuração da integração (só grava com ele ligado).
      def debug(integration, message) = DebugLog.log(integration, message)

      # Pareamento pelo app (Tuya hoje; ESPHome/Matter amanhã): o provedor de
      # pareamento do app pede a sessão da conta do SDK (`pairing_session` →
      # hash, nil = este plugin não pareia pelo app) e depois manda o aparelho
      # que pareou (`pair` → Device). Erro do formulário: Integrations::Error.
      def pairing_session(_site, _user) = nil
      # Campos que o app manda no `pair` (formato do `params.permit`).
      def pairing_params = [ :name, :area_id, :area_name ]
      def pair(_site, _form) = raise(Error, I18n.t("integrations.pairing.unsupported"))

      # ondaC1: tela "Gerenciar" da integração (as telas de rede do HA: Z-Wave,
      # Matter, Thread, Bluetooth). Plugin com `panel?` ganha o botão no card;
      # a tela é a partial `web/integrations/panels/_<key>` com as variáveis de
      # `panel_locals` (erro do serviço: Integrations::Error), e cada botão
      # dela posta uma ação (`panel_action(integração, ação, params)` →
      # Outcome; `:panel` volta para a tela). `panel_refresh` (ms) recarrega a
      # tela sozinha enquanto algo corre (inclusão, varredura). Sem partial
      # própria vale a genérica: `stats` [[rótulo, valor]], `rows` [[rótulo,
      # valor]] e `actions` [[ação, rótulo]] nas variáveis.
      def panel? = false
      def panel_locals(_integration, _params) = {}
      def panel_action(integration, _action, _params) = outcome(:panel, integration: integration)
      def panel_refresh(_integration) = nil

      # catalogo: tipos de aparelho que o próprio plugin dirige (SchemaPlugin); padrão: nenhum.
      def device_kinds = []
      def device_driver(_kind) = nil

      # Primeira configuração: adiciona um aparelho achado na rede sem formulário
      # (→ integração, com a varredura na fila) ou nil = precisa do assistente.
      def add_found(_site, _entry) = nil

      # A primeira varredura vem do login (polled_at agora: a periódica não corre antes dele).
      def new_integration(site, **attrs) = site.integrations.new(driver: driver, name: title, poll_s: Integration::SYNC_S, polled_at: Time.current, **attrs)
    end
  end
end
