# Migrar de outro sistema em sombra (F10)

Migrar automação de casa, loja ou fábrica sem susto: o Minha Automação recebe
a instalação inteira (aparelhos, áreas, helpers, automações, scripts e cenas)
e roda **em sombra** ao lado do sistema antigo. As automações disparam com os
eventos reais, mas nada sai: o que cada uma teria feito fica registrado, e um
comparador mostra, automação por automação, a diferença para o que o sistema
antigo fez de verdade. O corte acontece quando a comparação convence.

## Modo sombra

Vale em quatro níveis (o mais amplo ganha):

| Nível | Onde liga | Efeito |
|---|---|---|
| Automação ou script | Editor → "Em sombra" (ou em lote na lista) | Só ela fica segurada |
| Cena | Cadastro da cena → "Em sombra" | Acionar só registra as linhas |
| Local | Automações e cenas → Sombra → "Pôr o local em sombra" (dono) | Tudo do local: automações, scripts, cenas e regras simples (espelho, agenda, aviso, alerta) |
| Instalação | Configurações → Sistema → "Modo sombra da instalação" (dono) | Todos os locais |

O que roda e o que é segurado numa execução em sombra:

| Roda de verdade | Segurado ("teria feito") |
|---|---|
| Gatilho, condições, esperas, se/escolher/repetir, variáveis, parar | Comando em aparelho e cena |
| Leituras: previsão do tempo, agenda, consultar dados | Avisar, Falar, Gerar fala, Transcrever |
| Comando em helper que não comanda aparelho (liga/desliga, número, temporizador...) e chamar script (a execução do script herda a sombra) | Chamar HTTP, Pedir à IA, Gerar dados por IA |
| Disparar e esperar evento interno | Registrar dados; comando em grupo (ele comanda os membros) |

Decisão: helpers rodam porque são estado interno; assim cadeias como
"liga o temporizador → quando acaba, desliga a bomba" acontecem em sombra
(a segunda parte é segurada). O valor deles pode divergir do sistema antigo,
que muda os helpers por conta própria.

Como funciona por dentro:

- Cada plugin de ação diz se é seguro em sombra (`shadow_safe?`). O padrão é
  **não**: ação nova nasce segurada. A segurada roda como a simulação do
  editor e vira um `ShadowAction` com os pontos que comandaria (`effects`).
- Rede de segurança embaixo: com uma execução em sombra na thread,
  `Points::Command.call` não cria o comando (registra e levanta
  `Shadow::Blocked`), e `Notifier`, `SafeHttp` e `Ai::Request` levantam
  `Shadow::Blocked`. Num local em sombra, todo comando de origem
  `automation` (regras simples, desligar sozinho) também é segurado.
- A execução guarda `shadow` (aparece no trace com o ícone de lua); quem é
  disparado por ela (script, evento, fim de automação) herda a sombra.

## Assistente "Migre do HA em 10 minutos"

Integrações → **Migrar do Home Assistant** (`/locais/:id/migrar-do-ha`,
técnico ou dono), por cima do `HomeAssistantImport`:

1. **Conectar**: endereço do HA e um token de acesso longo (perfil do HA →
   Segurança). Ficam na integração `home_assistant` (a mesma do comparador;
   token cifrado). HA na rede de casa precisa estar na lista de liberados do
   `SafeHttp` (Configurações → Sistema). Testa `GET /api/` na hora.
2. **Revisar e escolher** (`HaMigrationJob` `fetch`): lê só para leitura
   (`Integrations::HaMigration.fetch`: REST `/api/states` e
   `/api/config/{automation,script,scene}/config/<id>`; WebSocket
   `config/{area,device,entity,label}_registry/list` e `config_entries/get`)
   e mostra áreas, aparelhos já reconhecidos, entidades, helpers, automações
   (ligada ou desligada no HA), scripts e cenas, cada item com caixa de
   marcar. Nada é gravado aqui; os arquivos não ficam guardados.
3. **Importar** (`HaMigrationJob` `import`): lê de novo, filtra pelo
   escolhido (`HaMigration.select`) e roda o importador com o progresso por
   passo (`HomeAssistantImport::STEPS`). Tudo em sombra.
4. **Conferir**: o que veio (contagens), o que virou blueprint (com ou sem
   perda e as notas) e o que ficou de fora e por quê (aparelho do HA sem
   equivalente, entidade sem ponto, helper que não converteu, entidade de
   cena perdida, item que não importou). Rodar de novo não duplica.

O estado fica em `integrations.settings["migration"]` (`status`:
`fetching`/`preview`/`importing`/`done`/`failed`). Spec com um HA falso no
lugar do transporte (`spec/support/fake_ha_transport.rb`, fixture
`spec/fixtures/files/ha_migracao.json`); nunca conecta num HA de verdade.
O `/api/states` passa pelo limite de 2 MB do `SafeHttp`.

## Passo a passo (Home Assistant)

1. **Ponha o local em sombra** antes de qualquer importação.
2. **Conecte as integrações daqui** que veem os mesmos aparelhos (ex.: Tuya /
   Smart Life por QR, Xiaomi, Alexa). Elas só leem até o corte.
3. **Importe** com os arquivos do HA numa pasta temporária (nunca no repo):
   `core.area_registry.json`, `core.device_registry.json`,
   `core.entity_registry.json` (de `/config/.storage`), `states.json`
   (`GET /api/states`), `automations.yaml`, `scripts.yaml` e `scenes.yaml`.

   ```bash
   bin/rails 'migracao:home_assistant[Casa,/tmp/ha]'
   ```

   O importador (`Integrations::HomeAssistantImport`) é idempotente pelo
   de-para e faz, nesta ordem: áreas pelo nome; adiciona os aparelhos que as
   integrações encontraram e ainda não estavam no local, na área do HA (e
   move os já cadastrados para ela); liga cada entidade do HA ao ponto daqui
   (aparelho pelo identificador do registro; ponto pelo código do dp, pelo
   dps do LocalTuya, pela propriedade MIoT ou pelo único ponto da
   capacidade); recria os helpers (`input_*`, `timer`, `counter`, grupos);
   cenas; scripts e automações pelo importador de blueprints, com as
   entradas resolvidas pelo de-para. Tudo nasce em sombra; automação fica
   ligada só se estiver ligada no HA. Apague a pasta depois.
4. **Confira** em Automações e cenas → Sombra: o de-para (o que ficou sem par)
   e, na saída da importação, a lista "COM PERDA" (Jinja não traduzido,
   entidade sem par, gatilho sem equivalente). Corrija no editor.
5. **Ligue a comparação**: Integrações → Home Assistant (migração), com o
   endereço e um token de acesso longo do HA (só GET). Libere o IP do HA em
   Configurações → Sistema → Saída HTTP. A comparação roda a cada 6 h sobre
   as últimas 24 h e há "Comparar agora". Sem token, dá para comparar com um
   diário baixado à parte:
   `bin/rails 'migracao:comparar[Casa,home_assistant,/tmp/logbook.json,6]'`.
6. **Deixe rodar** alguns dias, cobrindo dia, noite e fim de semana.

## Importar de novo (Lote 7)

O importador pode rodar quantas vezes precisar (sempre em sombra):

- publicada **sem perda** fica como está (pode ter sido revisada);
- **rascunho** ou publicada **com perda** é refeita **no mesmo registro**
  (mesmo id, mesmas execuções e "teria feito"), com o conversor e o de-para de
  agora; publica se a DSL fechar e só fica ligada se publicou nesta importação
  e está ligada no sistema antigo;
- além dos arquivos acima, entram `core.label_registry.json` (etiquetas do HA
  viram etiquetas dos pontos), `core.config_entries.json` (sensores template
  criados pela tela do HA viram sensor calculado quando o Jinja traduz, ex.:
  "Luzes acesas" = `count_points('tag=iluminação area=Cozinha state=on') > 0`;
  e o id de cada integração, para "Recarregar integração") e
  `configuration.yaml` (só o `rest_command:` é lido; `!include`/`!secret`
  ficam vazios).

O que o conversor passou a entender está em `docs/blueprints.md` (Lote 7).
Sem equivalente, de propósito:

- `shell_command`: rodar comando no servidor de uma instalação com vários
  clientes não é seguro; refaça com "Chamar HTTP", "Registrar dados" ou uma
  integração;
- cor de lâmpada (`rgb_color`): a capacidade `color` não recebe comando aqui;
- `media_player.play_media` (som na Echo), `conversation.process`, `ai_task`
  do HA, `camera.snapshot`, gatilho por atributo (`last_called_timestamp`) e
  alvo por etiqueta/área (`target: {label_id: ...}`);
- entidades sem par: celular (`mobile_app`/`device_tracker`, depende do app
  daqui), agendas Google (depende do login Google na integração Agenda),
  `tuya_camera_motion` e os eventos do robô no HA.

## Leitura do relatório

| Resultado | Quer dizer |
|---|---|
| Igual | Mesmos disparos e mesmos efeitos |
| MA a mais | Daqui disparou mais ou faria algo que lá não aconteceu |
| MA a menos | Lá disparou mais ou fez algo que aqui não faria |
| Diferente | Os dois lados fizeram coisas diferentes |
| Sem par no MA | Disparou lá e não foi importada |
| Sem disparo | Nenhum dos dois disparou na janela |

Efeito = entidade e estado ("switch.x=on"). Do lado do HA contam só os
domínios que recebem comando (sensor muda sozinho); efeito em entidade sem
de-para aparece à parte. Do lado daqui, alternar, apertar e rodar casam com
qualquer estado. Aviso, fala e HTTP não entram na conta (o HA não os registra
no diário), mas estão na linha do tempo "teria feito".

## Lote 8 (recursos genéricos que faltavam)

O importador passou a traduzir, sem nada da casa no código:

- `light.turn_on` com `brightness`/`brightness_pct`/`rgb_color`/`hs_color`/
  `color_temp_kelvin`/`color_temp` → "Ajustar" no ponto irmão (intensidade,
  cor) do mesmo aparelho. A entrada irmã tem o rótulo `entidade#capacidade`
  e o importador da instalação acha o ponto pela capacidade no aparelho.
- alvo `label_id`/`area_id` → "Comandar pontos por consulta" (`tag=…`,
  `area=… capability=onoff`; luz por área fica anotada, porque aqui a consulta
  não separa luz de tomada).
- `media_player.play_media` (som, rotina, música por provedor) e
  `volume_set` → comandos do ponto `speaker`.
- gatilho `state` com `attribute` → gatilho por atributo (avisa quando o
  ponto daqui não informa o atributo: converte, mas não dispara).
- `wait_for_trigger` de um estado (`to` + `for`) → "Esperar condição".
- Jinja `expand(...) | map(attribute='last_changed') | max/min`.
- entidade sem aparelho no HA pelo `unique_id` + classe; evento do robô por
  `_e_<siid>_<eiid>`.
- item publicado e solto do blueprint (assumido à mão) não é refeito.

## Entidades que ficavam sem par (painéis do HA)

- **Ação do aparelho** (`button.*` do `xiaomi_home`, `unique_id` terminando
  em `_a_<siid>_<aiid>`): não vira ponto próprio. O de-para aponta para o
  ponto que tem a ação (o robô, `address.actions`) com `kind`
  `command:<comando>`, e o painel importado faz o toque com esse comando
  ("Lavar pano" → `wash_mop`).
- **DP com outro nome**: o Tuya do HA e o Smart Life daqui chamam alguns DPs
  diferente (`va_humidity` × `humidity_value`): `TUYA_CODES`.
- **Mesma coisa, outra propriedade**: a falha do robô (o HA lê 2.3, aqui é o
  2.66 decodificado) casa pelo papel do ponto (`UID_ROLES`).
- **Serviços** (passo "Serviços"): clima (`met`/`open_meteo`), speedtest e o
  servidor (`hassio`, `uptime`, `backup`) → pontos das integrações daqui
  (`HaServiceEntities::SERVICES`). A integração que não pede nada (Clima,
  Speedtest, Sistema) nasce sozinha; entidade desativada no HA não cria nada.
- **Automação**: cada uma tem um ponto liga/desliga (`AutomationPoints`), e o
  interruptor `automation.*` do painel do HA aponta para ele.
- **Fire TV e grupo da Alexa** (`media_player` do `alexa_media`): a descoberta
  da Alexa traz as famílias `FIRE_TV` e `WHA` só com a mídia; o
  `media_player` casa com o `speaker` da Echo ou, sem ele, com a mídia.
- **Sensor template em YAML**: a API do HA não mostra; o assistente aceita o
  `configuration.yaml` (não fica guardado). Sem gatilho vira sensor calculado
  com os atributos (até 20); com gatilho é automação aqui e fica anotado. O
  tradutor do Jinja conta lista fixa de entidades (`key=`), aceita `none` e
  `| as_datetime`.
- **Energia do Tuya** (`add_ele`): o dp é o acréscimo; o ponto soma o que o
  aparelho empurra e começa do total que o HA tinha (`carry_total!`).
- **Card statistic** (quanto subiu hoje/no mês): stat com `aggregate:
  "change"` e `period`, pelo histórico do ponto.
- **Coluna vazia** (markdown só com `&nbsp;`, para alinhar 3 colunas): seção
  espaçadora (`"spacer": true`), sem texto e escondida no celular.
- **auto-entities** (HACS): Lista automática. Cada regra `include` vira uma
  consulta (`or`), com entidade fixa ou curinga → `id`, `domain` →
  capacidade (luz e interruptor sem as automações), `label` → etiqueta,
  `state` (`unavailable` → sem sinal), `attributes` (`device_class` e
  atributo do sensor calculado → `attr`), `last_triggered: "< N"` → `ran_min`;
  as `exclude` (entidade, curinga, integração) entram em todas. Card de
  tiles = grade de tiles com o `name` de cada regra; o `else` é o texto de
  vazio.
- **Falar na Alexa** (`custom:casa-campo-texto` com `seletor`/`audio`): widget
  `announce`, que manda direto para a Echo (sem o `input_text`, o script e o
  `shell_command` do HA).
- **Google Agenda** (`calendar.*` do `google`): casa com a agenda daqui pelo
  id (o `unique_id` do HA termina nele) depois que a pessoa conecta a conta
  Google na integração Agenda; os filtros "aniversários" e "local de trabalho"
  do HA não têm par.

Ficam de fora, e o relatório diz: agenda do Google antes de conectar a
integração Agenda, pessoas e bateria dos celulares (precisa do app em cada
celular), sensor template que só converte a leitura crua de um aparelho (aqui
o ponto já está na unidade: aponte o painel para ele) e o que vem de comando
de shell no HA (`shell_command`, de propósito).

## Fonte de referência nova

Um plugin de integração (`Integrations::PLUGINS`) que responde a:

- `reference(integration, from, to, entries:)` →
  `{id na origem → {"name", "runs", "effects" => [[entidade, estado]]}}`
  (`entries` = dados já lidos, para testes e comparação offline);
- `state_for(comando, valor)` → o estado que a origem mostraria ("*" = qualquer).

O de-para é `ExternalRef` com `source` = chave do plugin (automação de lá →
`Automation`, entidade de lá → `Point`). O comparador (`Shadow::Compare`) e a
tela não mudam.

## Corte (cutover)

Por automação, quando a comparação dela estiver "Igual" há alguns dias:

1. Desligue a automação no sistema antigo.
2. Aqui, se o local estiver em sombra, primeiro marque "Em sombra" em todas
   (lote → "Pôr em sombra") e tire o local da sombra; depois tire da sombra
   só as que vão assumir.
3. Acompanhe em Execuções e no aparelho.

No dia do corte geral: desligue as automações do sistema antigo, tire a
sombra (local e automações), troque a skill/integração de voz para a daqui,
reaponte o app e os painéis, e mantenha o sistema antigo parado (não
apagado) por uns dias para voltar se precisar.

## Fechamento antes do corte (Lote 9)

- Gatilho por atributo leva os atributos do ponto em `trigger.attrs` (o
  `trigger.to_state.attributes` do HA).
- A última fala às Echo vira atributo (`docs/integracoes.md`, Lote 9): o
  "Alexa, boa noite" do `alexa_media` (`last_called_*`) funciona igual.
- Seleção importada do HA vem com uma opção por linha (antes virava uma
  opção só).
- Itens refeitos à mão no local (soltos do blueprint) não são tocados pela
  reimportação. O que sobra em rascunho depende do usuário: agendas Google
  (login na integração Agenda) e celular (app do MA no celular, G17).
- Webhook: o do HA (`/api/webhook/<id>`) não migra; a automação daqui tem
  gatilho Webhook com token próprio e quem chamava precisa trocar a URL.
