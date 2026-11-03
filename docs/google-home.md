# Google Home (cloud-to-cloud)

O Minha Automação fala direto com o Google Home e o Google Assistente, sem
Matter: os pontos marcados na coluna **Google Home** da tela **Expor**
aparecem no app Google Home e atendem por voz. Tudo do lado do MA já existe
(integração "Google Home", `POST /google/smart_home`, OAuth em
`/oauth/autorizar` e `/oauth/token`, HomeGraph). O que falta é o projeto do
dono no Google, que só ele pode criar.

## O que o dono precisa criar no Google (uma vez)

1. **Acesso remoto ligado.** O Google chama o MA pela internet
   (`https://<seu endereço>/google/smart_home`). Use o acesso remoto do MA
   (túnel) com HTTPS válido.
2. **Projeto no Google Home Developer Console**
   (<https://console.home.google.com>): "Create project" → anote o
   **Project ID** (ex.: `minha-casa-12345`).
3. No MA: Integrações → adicionar **Google Home** → cole o Project ID. A
   tela **Gerenciar** mostra tudo o que vai para o Console.
4. No Console: "Add cloud-to-cloud integration" e preencha:
   - **Fulfillment URL**: a da tela Gerenciar (`…/google/smart_home`).
   - **OAuth Client ID**: o "Client ID" da tela (`ma-google-…`).
   - **Client secret**: botão "Gerar segredo do cliente" (aparece uma vez).
   - **Authorization URL**: `…/oauth/autorizar`.
   - **Token URL**: `…/oauth/token`.
   - Tipos de aparelho: os que for expor (luz, tomada, interruptor,
     termostato, garagem, persiana, sensor, cena).
5. **Estado na hora (opcional, recomendado).** No Google Cloud do mesmo
   projeto: ative a **HomeGraph API**, crie uma **conta de serviço**, gere
   uma chave JSON e cole em Integrações → Google Home → Reconfigurar. Com
   ela o MA manda cada mudança (Report State) e a lista se atualiza
   sozinha ("Sincronizar com o Google" = Request Sync).
6. **Testar**: no app Google Home → Adicionar → "Funciona com o Google" →
   procure `[test] <nome do projeto>` → entre com a conta do MA e escolha o
   local. Só aparece o que está marcado em Expor.

## Regras do MA

- Só entra o ponto marcado na coluna Google Home da tela Expor; o comando
  passa pelo papel da pessoa × risco, com origem "Google Home" no histórico.
- Ponto crítico (portão, fechadura, sirene) só entra com confirmação, e na
  hora do comando o próprio Google pergunta "tem certeza?" (desafio
  `ackNeeded`).
- Desvincular: na tela Gerenciar ou tirando a integração no app Google
  Home (o Google manda DISCONNECT e o token é revogado).

## Como foi testado

Sem projeto real: `spec/requests/onda_c1_google_spec.rb` faz o account
linking de verdade (autorizar, código, token), as intenções SYNC/QUERY/
EXECUTE/DISCONNECT nos formatos da documentação do Google e o HomeGraph com
WebMock (JWT assinado por uma conta de serviço gerada no teste).
