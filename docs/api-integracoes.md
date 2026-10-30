# Integração com os outros sistemas da suíte (F9)

minhas-vendas, minhas-compras, meu-gestor ou qualquer outro sistema falam com
a Minha Automação sem código específico de nenhum deles: **entrada** pela API
com uma chave de integração, **saída** pela ação "Chamar HTTP / webhook" e
pelo gatilho webhook. Contrato completo da API em `docs/api/openapi.yaml`.

## Entrada: chave de integração

**Configurações → Chaves** (dono): nome, locais e permissões (`read`,
`command`, `write`). A chave (`svc_...`) aparece uma vez; o outro sistema
manda no cabeçalho `X-Api-Key`. Fora dos locais da chave = 404; ação sem a
permissão = 403; papel x risco continuam valendo (chave do dono).

Base: `https://casa-automacao.minhasuite.com/api/v1` (na rede de casa,
`http://192.168.68.199/api/v1`). Respostas no envelope `{data, meta}`; erro
`{error: {code, message}}`.

### minhas-vendas muda o preço de um e-ink (escrever valor)

Crie um helper **Texto** ou **Número** ("Preço do café", chave
`helpers.preco_cafe`) e aponte o e-ink/painel para ele. O sistema escreve:

```bash
curl -X POST "$BASE/points/<id do ponto>/value" \
  -H "X-Api-Key: $CHAVE" -H "Content-Type: application/json" \
  -d '{"value": "12,90"}'
```

Permissão `write`. Só ponto de dispositivo virtual (helpers) aceita valor de
fora; o helper valida (mínimo/máximo/passo, opções da lista). O id sai de
`GET /sites/<local>/devices` → pontos, ou da página do helper.

Mudou o valor = o ponto mudou: automações com gatilho nesse ponto disparam
e o painel atualiza na hora.

### meu-gestor aciona um script

```bash
curl -X POST "$BASE/scripts/<id do script>/run" \
  -H "X-Api-Key: $CHAVE" -H "Content-Type: application/json" \
  -d '{"fields": {"mensagem": "Pedido 123 pronto"}}'
```

Permissão `command`; resposta **202** com a execução. Script que comanda
ponto crítico exige `"confirm_critical": true`. Ver campos e execuções:
`GET /scripts/<id>` e `GET /scripts/<id>/runs` (`read`).

### Comandar um ponto ou ler o estado

```bash
curl -X POST "$BASE/points/<id>/commands" -H "X-Api-Key: $CHAVE" -H "Content-Type: application/json" -d '{"command": "on"}'
curl "$BASE/points/<id>" -H "X-Api-Key: $CHAVE"
curl "$BASE/points/<id>/history?from=2026-10-01T00:00:00-03:00&resolution=1d" -H "X-Api-Key: $CHAVE"
```

### Disparar uma automação (webhook de entrada)

Gatilho **Webhook** na automação → "Gerar token" (mostrado uma vez):

```bash
curl -X POST "$BASE/hooks/automations/<token>" -H "Content-Type: application/json" \
  -d '{"mensagem": "Estoque de leite baixo", "canal": "celular"}'
```

Sem login (o token é o segredo), até 10 KB, 60/min. O corpo chega em
`{{ trigger.data.campo }}` nos textos da automação.

## Saída: ação "Chamar HTTP / webhook"

No editor de automação ou script: **Chamar HTTP / webhook** (`type: "http"`).

| Campo | |
|---|---|
| `method` | GET, POST, PUT, PATCH, DELETE |
| `url` | texto Liquid (`https://vendas.../hook?loja={{ site.name }}`) |
| `headers` | um por linha, `Nome: valor` (Liquid) |
| `secret` | token/senha guardado **cifrado** na definição; entra como `{{ secret }}` em URL, cabeçalhos ou corpo; nunca aparece no trace nem na tela |
| `body` | texto Liquid (JSON montado à mão) |
| `timeout` | 1 a 30 s (padrão 10) |

A resposta vira as variáveis `http_status` e `http_body` (até 1000
caracteres) para os passos seguintes. Status 400+ ou falha de rede = execução
"Falhou". Na simulação nada é enviado.

```json
{ "type": "http", "method": "POST", "url": "https://minhasvendas.minhasuite.com/api/webhooks/casa",
  "headers": "Authorization: Bearer {{ secret }}\nContent-Type: application/json",
  "secret": "tok_...", "body": "{\"evento\": \"porta_aberta\", \"quando\": \"{{ now | date: '%H:%M' }}\"}" }
```

### Proteção contra SSRF

Toda saída para endereço digitado (esta ação e as agendas por link) passa
pelo `SafeHttp`: só `http`/`https`; IP privado, loopback, link-local
(inclusive `169.254.169.254`), CGNAT, multicast e os equivalentes IPv6 são
**bloqueados por padrão**, inclusive depois de redirect (até 3, cada salto
checado) e com a conexão presa ao IP checado (sem DNS rebinding). Para chamar
um sistema da rede de casa, o dono libera em **Configurações → Sistema →
Saída HTTP** (host exato ou faixa CIDR, ex. `192.168.68.0/24`), por
instalação.
