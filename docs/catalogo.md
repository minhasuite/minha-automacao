# Catálogo de integrações (grupo 9 da paridade com o HA)

As integrações mais instaladas do Home Assistant, como plugins do MA. Todas
entram por `Integrations::PLUGINS`, sem mexer no núcleo.

## Como uma integração do catálogo é feita (`Integrations::SchemaPlugin`)

```ruby
class FooPlugin < SchemaPlugin
  describe key: "foo", title: "Foo", icon: "bolt", description: "…"
  texts en: { title: "Foo", description: "…", fields: { zone: "Zone" } }, es: { … }, "pt-BR" => { fields: { zone: "Zona" } }
  field :host, required: true          # :text (padrão), :number, :url, :select (options:)
  field :zone, :select, options: %w[a b], default: "a"
  field :token, secret: true           # cifrado; vazio no Reconfigurar mantém o guardado

  def self.entries(integration) = [ entry(id: "foo:1", name: "Foo", points: [ point("power", unit: "W"), point("on", "onoff") ]) ]
  def self.read(device) = { "power" => 12.3, "on" => true }  # campo do ponto → valor
  def self.write(point, value) = …                             # ponto gravável
  def self.command(point, command, value) = …                  # opcional: mídia (pause, next…)
end
```

- **Formulário gerado dos campos**: a partial `web/integrations/forms/_schema`
  (só se o plugin não tiver `forms/_<key>` própria). O app recebe a mesma tela
  pelo `/api/v1/screen` (transcodificada), então web e app saem do mesmo schema.
- **O plugin é o driver**: `Drivers.klass` e `Polling.driver_for` perguntam a
  `Integrations.device_driver(kind)` quando o driver não está nos registros
  antigos. Leitura periódica pelo `poll_s` da entrada; comando pelo
  `ExecuteCommandJob` → `write`/`command`.
- **Textos**: rótulo do campo em `fields.<campo>`, dica em `hints.<campo>`,
  opção em `options.<campo>.<opção>`, nome do ponto em `points.<campo>` e nota
  do formulário em `note`. Os comuns (endereço, porta, usuário, senha, token,
  potência, energia, temperatura…) já vêm da base, nos três idiomas.
- **Descoberta**: `mdns`, `ssdp` e `dhcp` como em qualquer plugin; com campo
  `host` e nenhum outro obrigatório, o achado na rede entra sem formulário.
- **Teste**: `spec/services/catalogo_spec.rb` (plugin falso por `stub_const`,
  respostas gravadas com WebMock e aparelhos de mentira em 127.0.0.1) e
  `spec/requests/catalogo_spec.rb` (todo SchemaPlugin aparece no catálogo e o
  formulário sai dos campos).

## Integrações

| Integração | Como fala | O que o dono precisa |
|---|---|---|
| WiZ | UDP 38899 local (`getPilot`/`setPilot`) | só o IP |
| TP-Link Kasa / Tapo | Kasa: TCP 9999 (XOR); Tapo: KLAP v2 no HTTP 80 | Tapo: e-mail e senha da conta TP-Link (o aparelho confere o hash na rede) |
| AdGuard Home | API `/control/*` | usuário e senha do painel |
| Nobreak (NUT) | `upsd` TCP 3493 | usuário/senha do `upsd` se exigir |
| Fully Kiosk Browser | API REST do app (2323) | ligar "Remote Administration" e a senha |
