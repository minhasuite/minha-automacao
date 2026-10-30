# Scripts (F8f)

Script é uma sequência de ações reutilizável, como o `script` do HA. Por
dentro é uma `Automation` de `kind: "script"`: o mesmo editor de blocos (só a
lista de ações), as mesmas versões (publicar, descartar, voltar), os mesmos
modos (`single`, `restart`, `queued`, `parallel`) e as mesmas execuções com
trace. Não tem gatilho nem condição: a validação recusa.

Tela: aba **Scripts** da seção "Automações e cenas" do local
(`/locais/:id/scripts`); editar em `/automacoes/:id/editar`.

## Campos

`automations.fields` = `[{name, label, type, default?, required, options?}]`,
editados na hora (fora do rascunho) na seção "Campos" do editor.

| type | valor | formulário |
|---|---|---|
| `text` | texto (até 500) | caixa de texto |
| `number` | número (`"2,5"` → 2.5) | caixa numérica |
| `boolean` | verdadeiro/falso | Sim/Não |
| `point` | UUID do ponto (aceita a `key`) | lista de pontos |
| `select` | uma das `options` | lista |

`name` é nome de variável (`a-z`, `0-9`, `_`). Sem valor, vale o `default`;
`required` sem `default` e sem valor = erro ("Falta o campo Luz"). Na
sequência o campo é variável: `{{ nome }}` nos textos, `nome` nas
expressões e **`$nome` no ponto** de um bloco (ex.: `"point": "$alvo"`).

## Quem chama

- **Automação**: ação `script` (`"Executar script"`) com `fields`
  (`{campo: valor}`; texto com `{{ }}` é montado na hora). O script roda como
  execução própria (trace dele), ligada à da automação por `cause_run`:
  script que se chama vira "Laço evitado". Falha do script falha a ação; modo
  que barrou = passo "skipped".
- **Painel**: cada script tem um ponto de capacidade `script` (comando `run`)
  no dispositivo virtual "Scripts" do local (`Scripts`, `external_id:
  "scripts"`, fora da lista de dispositivos). O tile mostra "Executar"; o
  risco do ponto é o da versão publicada. É por esse ponto que a Skill da
  Alexa (F9) vai expor o script.
- **API**: `POST /api/v1/scripts/:id/run {fields, confirm_critical?}` → 202
  com a execução. Papel do risco dos pontos do script e dos escolhidos nos
  campos (`run_risk`); com chave de integração, permissão `command` e o local
  na chave. Também `GET/POST /sites/:id/scripts`, `GET/PATCH/DELETE
  /scripts/:id`, `GET /scripts/:id/runs` (`docs/api/openapi.yaml`).
- **Tela**: botão "Executar" (com campos, abre o formulário `/automacoes/:id/executar`).

## Exemplo

```json
{ "actions": [
  { "type": "command", "point": "$alvo", "command": "on" },
  { "type": "wait", "expr": "minutos * 60" },
  { "type": "command", "point": "$alvo", "command": "off" },
  { "type": "notify", "channels": ["in_app"], "title": "{{ recado }}" } ] }
```

Campos: `alvo` (ponto, obrigatório), `minutos` (número, padrão 5) e
`recado` (texto, padrão "Pronto").
