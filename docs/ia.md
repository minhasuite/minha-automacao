# IA da instalação (Lote 2)

O equivalente ao `ai_task` e ao `conversation` do Home Assistant. Usa a chave
do próprio usuário, por provedor, guardada cifrada no banco. Não depende do
plano nem da cota da suíte (a IA da suíte, `Ai::Client` por tier com chave
em env, continua para as features do app e usa os mesmos plugins).

## Provedores como plugins

Cada provedor é uma classe em `app/services/ai/providers/`, subclasse de
`Ai::Providers::Base`, registrada em `Ai::PROVIDERS`
(`app/services/ai.rb`). Nada de `case` por provedor fora dela: a tela, a
ação, o "Perguntar à casa" e a IA da suíte perguntam ao registro.

```ruby
class Ai::Providers::MeuProvedor < Ai::Providers::Base
  describe key: "meu", label: "Meu provedor", default_model: "m-1", models: %w[m-1 m-2],
           capabilities: %i[text image structured], env: nil, base_url: "https://api.exemplo.com",
           custom_url: false, key_required: true, hint: "Onde pegar a chave."

  def complete(model:, system:, user:, schema:, max_tokens:, timeout:, effort: nil, temperature: nil)
    # user: texto ou blocos [{type: "image", source: {media_type, data}}, {type: "text", text}]
    # schema nil = texto livre. Devolve Result.new(data:, usage: {input:, output:}).
  end
end
```

Mais o nome em `Ai::PROVIDERS` e um spec. `capabilities` (de
`Ai::CAPABILITIES`): `text`, `image`, `structured` (JSON schema), `tools`,
`temperature`. O `Ai::Request` recusa imagem ou saída estruturada em quem não
declara, e só manda a temperatura para quem declara. Erro: `Ai::Client::Error`
ou `TransientError` (429, 5xx, rede), sempre com mensagem genérica; o corpo
cru da resposta vai só para o log, sem o prompt.

| Provedor | Chave | Modelo padrão | Observação |
|---|---|---|---|
| `anthropic` | console.anthropic.com | `claude-sonnet-5-5` (`claude-haiku-5-5` é a opção barata) | gem `anthropic`; saída estruturada por `output_config.format`; sem temperatura (os modelos 5.5 recusam) |
| `openai` | platform.openai.com | `gpt-5-mini` | `/chat/completions` por Net::HTTP; sem temperatura (modelos de raciocínio) |
| `gemini` | aistudio.google.com | `gemini-3.5-flash` | `generateContent` por Net::HTTP |
| `ollama` | opcional | `llama3.2` (`llava`, `qwen2.5vl`, `gemma3` para imagem) | URL configurável, pelo `SafeHttp`: libere o IP em Configurações → Sistema → Saída HTTP |
| `local_audio` | opcional | `whisper-1` (transcrição), `tts-1` (fala) | Só voz (Lote 5): servidor da casa compatível com `/v1/audio` (faster-whisper-server/speaches, openedai-speech com Piper), pelo `SafeHttp` |

### Voz (Lote 5, G14)

`stt` (voz para texto) e `tts` (texto para fala) são capacidades como as
outras. O provedor que as declara implementa `transcribe(audio:, media_type:,
model:, language:, timeout:)` e `speak(text:, model:, voice:, timeout:)` e
diz `stt_model`, `tts_model` e `tts_voice`. OpenAI (`gpt-4o-mini-transcribe`,
`gpt-4o-mini-tts`) e "Voz local" usam o mesmo formato
(`Ai::Providers::OpenaiAudio`); Gemini transcreve pelo `generateContent` e
fala em PCM, que vira WAV. `Ai::Audio` escolhe a conta com a capacidade
(`AiAccount.pick(capability:)`: provedor só de voz não entra na escolha de
texto), confere o limite do mês e registra o `AiCall` sem o áudio nem o
texto. O "Testar conexão" de provedor só de voz gera uma fala curta.

## Configurações → IA

`/configuracoes/ia` (administradores veem, o Dono muda):
- Um cartão por provedor: chave (`AiAccount.api_key`, `encrypts`; vazio
  mantém a guardada; nunca volta para a tela), endereço (só Ollama), modelo,
  ligado e "Testar conexão" (pergunta curta, conta como chamada `teste`).
- Provedor padrão e limite do mês em US$ e/ou em chamadas
  (`tenants.settings["ai"]`: `default_provider`, `limit_usd`, `limit_calls`).
- Uso: cada chamada (`AiCall`): origem (automação, pergunta, teste), local,
  provedor, modelo, tokens, custo estimado (`ModelPrice`) e resultado. Nunca o
  prompt nem a resposta.

**Limite (`Ai::Budget`)**: passou do limite, a próxima chamada é bloqueada
(`AiCall` com `status: "blocked"`, não conta no gasto) e os administradores
recebem um aviso, uma vez por mês (`dedup_key`). Com `continue_on_error`, a
automação segue.

## Ações da DSL

- **`ai_task` "Pedir à IA"**: pedido em Liquid (pontos, variáveis,
  `trigger`), instruções de sistema, imagens (quadro das câmeras agora pelo
  go2rtc, URL https pelo `SafeHttp` ou anexo `/rails/active_storage/...`, até
  4), saída livre ou estruturada (um campo por linha, `nome: texto|número|
  inteiro|sim/não|lista descrição`, ou um JSON schema de objeto),
  temperatura, limite de tokens, provedor e modelo opcionais. Resposta pelo
  contrato `response_variable`: `{data, provider, model, tokens, cost}`
  (`{{ ia.data }}`, `ia.data.anomalia` na expressão). O trace mostra só
  provedor, modelo, tokens e quantas imagens.
- **`ai_data` "Gerar dados por IA"**: o mesmo, com o estado da casa antes do
  pedido (`Ai::PointContext`): os pontos escolhidos por ponto, área (do ponto
  ou do dispositivo) ou etiqueta, até 150, com valor, qualidade, há quanto
  tempo mudou e, com `history`, leituras, mínimo, máximo e média na janela.
  O "vigia de anomalia" e o "resumo da semana" do HA são automações do
  usuário com esta ação (e "Consultar dados" para o histórico), não código.

- **`stt` "Transcrever áudio"** (Lote 5): áudio por URL https ou anexo
  `/rails/active_storage/...`, idioma, provedor e modelo opcionais. Resposta
  `{text, provider, model}` (`{{ fala.text }}`), que pode ir para "Pedir à IA".
- **`tts` "Gerar fala"** (Lote 5): texto Liquid, voz, provedor e modelo
  opcionais. O áudio vira anexo com URL assinada que vale 1 dia (e é apagado
  depois). Resposta `{url, content_type, bytes, provider, model}`.

Simulação não chama a IA.

## Perguntar à casa

`/perguntar` (menu lateral): escolhe o local e pergunta. O contexto é o
estado de todos os pontos do local (até 150) e o resumo das últimas 6 horas.
Só leitura nesta fase: a IA não executa comando. Conta como chamada
`pergunta` no limite.

## Como ligar (o usuário)

1. Pegue uma chave no provedor (ex.: console.anthropic.com → API keys).
2. Em Configurações → IA, cole no cartão do provedor, salve e toque em
   "Testar conexão".
3. Escolha o provedor padrão e um limite do mês (ex.: US$ 5).
4. Numa automação, use "Pedir à IA" ou "Gerar dados por IA".

Nunca há chave no repositório, no `.env` do servidor ou no log.

## Fora desta fase

Ferramentas (a IA chamar comandos) e conversa com histórico. A capacidade
`tools` já é declarada pelos plugins para quando a IA puder agir.
