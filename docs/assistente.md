# Assistente de voz (Pacote 3)

O Assist do HA: microfone (web e app) → STT da instalação (capacidade `stt`
de `Ai::CAPABILITIES`) → intenção local → resposta em texto e, se houver
provedor `tts`, fala.

## Fluxo

1. Web: botão **Falar** no topo do painel (`web/assist/_button`, Stimulus
   `assist`). Grava com `MediaRecorder` (só em https/localhost; em http da
   rede de casa, escreva o texto) e manda para `POST /assistente`.
   App: botão de microfone no Início → `POST /api/v1/sites/:id/assist`.
2. `Assist.transcribe` (áudio → texto) e `Assist.call(site:, user:, text:, speak:)`.
3. Intenções de `Assist::INTENTS`, na ordem, sobre a frase normalizada (sem
   acento, minúsculas):
   - `TurnOnOff`: "ligar/acender/desligar/apagar X";
   - `ReadState`: "qual/quanto/como (está) X";
   - `ActivateScene`: "ativar/acionar (a cena) X".
   X é resolvido por `Assist.find_points`: nome, apelido falado (Alexa),
   "ponto da área", área inteira e, por último, todas as palavras.
4. Nenhuma reconheceu: "Perguntar à casa" (`Ai::Ask`, só leitura). Sem IA
   configurada, responde que não entendeu.

## Segurança

- Comando por voz usa `source: "voice"` e o usuário que falou; segue o papel
  x risco dele; **ponto ou cena crítica nunca por voz**.
- Respeita a sombra do local (`Shadow.for_site`): aparelho não recebe nada.
- Chave de integração não usa o assistente.
- A fala gerada é anexo com URL assinada de 1 dia (`Ai::Audio.store`).
- Chamadas de IA ficam em `AiCall` com origem "voz" (sem áudio nem texto).

## Estender

Intenção nova = classe em `Assist::Intents` com `pattern` (regex) e
`handle(ctx, match)` → `Assist::Reply` ou nil + nome em `INTENTS`. Prova com
`stub_const` em `spec/services/pacote3_platform_spec.rb`.
