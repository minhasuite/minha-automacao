# Loja de pacotes (Pacote 3)

O HACS do HA, só declarativo: um pacote é um **manifesto versionado** com
itens que entram nos registros que já existem. **Nunca código** (Ruby, JS,
shell): só há os tipos de item de `Packages::ITEMS`, cada item é validado
pelo próprio registro e nada do pacote é executado.

## Onde

Local → **Pacotes** (`/locais/:id/pacotes`): URL → **Ver o que entra**
(pré-visualização com erros e o plano: entra, atualiza, sai) → Instalar.
Na página do pacote: **Procurar versão nova** e **Remover** (tira o que ele
pôs). Ver: qualquer papel; instalar/atualizar/remover: técnico ou dono.
API: `/api/v1/sites/:id/packages` (+ `/preview`) e `/api/v1/packages/:id`.

## Fontes (`Packages::SOURCES`)

- `https://github.com/dono/repo[/tree/ref]` → `minha-automacao.json|yml|yaml` na raiz (raw).
- `https://gitlab.com/grupo/repo` → idem.
- URL https direta do manifesto (`.json`, `.yml`, `.yaml`).

Tudo pelo `SafeHttp` (IP interno bloqueado), até 512 KB, YAML só com
`safe_load`. Clonar repositório git qualquer ficou de fora de propósito (rodar
`git` com URL de terceiro no servidor não é necessário para ler um manifesto).

## Manifesto

```json
{
  "format": 1,
  "key": "luzes-basicas",
  "name": "Luzes básicas",
  "version": "1.2.0",
  "description": "Blueprints de luz por movimento e um modo da casa",
  "author": "Fulano",
  "items": [
    { "type": "blueprint", "key": "luz-movimento", "name": "Luz por movimento", "domain": "automation", "mode": "restart",
      "inputs": [ { "key": "luz", "label": "Luz", "type": "point" } ],
      "definition": { "triggers": [ { "type": "manual" } ], "actions": [ { "type": "command", "point": { "!input": "luz" }, "command": "on" } ] } },
    { "type": "helper", "key": "modo", "name": "Modo da casa", "helper": "select", "form": { "options_text": "Casa, Fora, Noite" } },
    { "type": "dashboard", "key": "painel", "name": "Painel pronto", "icon": "home", "definition": { "schema_version": 1, "views": [] } },
    { "type": "device_map", "key": "tomada-x", "map": "tuya",
      "data": { "codes": { "add_ele_x": { "name": "Energia", "capability": "measure", "unit": "kWh" } } } }
  ]
}
```

| Tipo | Vira | Validação |
| --- | --- | --- |
| `blueprint` | Blueprint do local (`source: package:<key>`) | o model `Blueprint` |
| `helper` | Helper (`helper` = tipo de `HelperTypes`, `form` = campos do formulário) | o plugin do tipo |
| `dashboard` | Painel do local (formato da F5) | `Dashboards::Schema` |
| `device_map` | Soma ao mapa `tuya` ou `miot` (`DeviceMaps`) | só seções de `DeviceMaps::MERGEABLE` (códigos, categorias, propriedades…), só dados; regex (`patterns`, `skip`) fica no arquivo |

`key` do pacote e dos itens: minúsculas, números, `-` e `_` (2 a 60).
Instalar de novo a mesma `key` = atualizar: item com a mesma `type`+`key` é
refeito no mesmo registro, o que saiu do manifesto é removido. Tudo ou nada
(transação). Mapas de dados valem para a instalação (cache de 60 s, limpo ao
instalar/remover).

## Estender

- Fonte nova: classe em `Packages::Sources` com `match?(url)` e `candidates(url)` + nome em `SOURCES`.
- Tipo de item novo: classe em `Packages::Items` (`describe key:, label:`,
  `errors`, `install!` → id, `uninstall!`, `path`) + nome em `ITEMS`.
- Mapa novo: arquivo + linha em `DeviceMaps::FILES` e `MERGEABLE`, e o serviço lendo por `DeviceMaps.apply`.

Provas com `stub_const` e fixtures (WebMock) em `spec/services/pacote3_platform_spec.rb`.

## Card de painel (`card`, ondaA2)

Card de terceiros em JavaScript (como os "custom cards" do HACS):

```json
{ "type": "card", "key": "meu-card", "name": "Meu card", "url": "https://cdn.exemplo.com/meu-card.js",
  "sha256": "sha256-<base64>", "element": "meu-card" }
```

- `sha256`: hash do arquivo (hexa ou o formato do atributo `integrity`). O
  arquivo é baixado uma vez, conferido e guardado pelo hash; se não bater,
  o pacote não instala.
- No painel, o widget "Card de terceiros" roda o card num iframe `sandbox`
  (origem opaca: sem cookie, sem acesso à página nem à API) com `integrity`
  no script. O card recebe `setConfig(config)` e `hass.states` só dos
  pontos escolhidos (entity_id = chave do ponto), como no HA; cards que só
  mostram estado funcionam sem mudança. Comandar a partir do card não existe
  (de propósito: o código de terceiros não fala com a casa).
