# Proposta: o MA nos clientes do integrador (várias instalações)

Aprovada em 24/11/2026 (etapas 1 a 3 e o freio feitos no mesmo dia; ver "Andamento" no fim). Cenário: o Herlon instala e mantém o Minha Automação na casa ou empresa
dos clientes dele. A plataforma continua livre (Apache 2.0): nada aqui é cobrança, licença ou nuvem paga. O
objetivo é cuidar de N instalações sem ir lá e sem entrar por SSH em cada uma.

## Onde estamos (24/11/2026)

| Peça | Estado |
|---|---|
| Saúde da instalação | Existe: `Health::CHECKS` (integrações, aparelhos, confiabilidade, filas, backup, disco, desempenho…) em Configurações → Saúde, com aviso diário ao dono |
| Métricas do servidor | Existem como pontos da integração Sistema (`SystemPlugin::METRICS`: disco, CPU, memória, atualização disponível…). **Falta** temperatura e "ficou sem rede" |
| Backup fora do local | Existe (`docs/backup.md`): cifra e manda de hora em hora (Google Drive, SSH, S3) e **restaura num banco temporário todo domingo**. Na casa do Herlon: Drive, 14 cópias, restauração ok em 22/11 |
| Atualização | Existe (`docs/instalacao.md`, `PROPOSTA-distribuicao.md`): canais Beta/Estável, atualizar sozinho na janela, volta sozinho se falhar. A casa ainda recebe por `bin/deploy-local` (fora do caminho do cliente) |
| Ver todas as instalações | **Não existe.** Hoje é SSH + consulta em cada servidor |
| Acesso remoto | Túnel montado à mão (casa do Herlon); o registro `RemoteAccess::PROVIDERS` existe |

## 1. Sinal de vida: cada instalação conta como está

A cada 5 minutos (e na hora, quando algo muda de estado) a instalação manda um resumo para a central do
integrador (`POST` https, um token por instalação):

- **Identidade**: id da instalação, nome do cliente, versão e canal.
- **Servidor**: tempo ligado, **temperatura da CPU** (nova, de `/sys/class/hwmon`), carga, memória, disco,
  worker vivo (batimento do Solid Queue), fila atrasada.
- **Rede**: se a internet e a rede de casa respondem; ao voltar de uma queda, **quanto tempo ficou fora**
  (o envio que não saiu fica guardado e vai quando a rede volta).
- **Casa**: as verificações de Saúde que já existem (só o status e quantos problemas por verificação), contagem de
  aparelhos e de pontos sem sinal, comandos que falharam e automações com erro nas últimas 24 h, chamadas de IA com
  erro. **Só contagens**: nome de aparelho fica de fora (na casa piloto, "Echo Suíte Eva" carrega o nome de uma pessoa).
- **Backup**: último dump local, última cópia fora, último teste de restauração e o resultado.

**Fica de fora, de propósito (LGPD e confiança do cliente)**: imagem de câmera, nome de pessoa, localização,
conteúdo de aviso, histórico de leituras. A central vê **se** a casa está bem, não **o que** acontece nela.

Do lado do MA: uma classe `Integrator::Report` monta o resumo a partir do `Health` e do `SystemPlugin` (nada
calculado duas vezes) e um job recorrente manda (`IntegratorReportJob`). Liga com `INTEGRATOR_URL` e
`INTEGRATOR_TOKEN` no `.env` (sem eles, desligado, como as outras credenciais).

## 2. A central do integrador

**A própria Minha Automação, numa instância só dela na VPS, no papel de central** (mesma imagem, banco e
subdomínio próprios). Não é a instância de demonstração da VPS: aquela existe para o revisor da Play, com login de
teste, e não pode ver cliente. Reaproveita login, papéis, avisos com push para o celular do Herlon, a tela no padrão
Lista Clara e o app. Nada de produto novo. A tela só aparece onde `INTEGRATOR_HUB=1`.

- **Lista de clientes** com semáforo (ok / atenção / com erro), visto por último, versão, temperatura, disco,
  backup e o problema principal. Ordenada por quem precisa de atenção.
- **Página do cliente**: o último resumo, gráfico de temperatura/disco/memória (os resumos viram leituras, então
  o gráfico e o histórico que já existem servem), e o atalho para o acesso remoto dele.
- **Avisos para o integrador** (não para o cliente), com o "voltou" quando resolve:
  - sem sinal há 15 min;
  - temperatura acima de 90 °C;
  - disco acima de 85%;
  - backup fora do local atrasado (mais de 36 h) ou teste de restauração falhou;
  - worker parado ou fila atrasada;
  - versão atrás da estável há mais de 7 dias;
  - ficou sem rede (com a duração).
- O token de cada instalação nasce na central ("Nova instalação" → token para o `.env` do cliente).

Alternativa mais simples, se preferir começar menor: um monitor "push" no Uptime Kuma por cliente. Só diz se
está vivo (nada de temperatura, backup ou problemas), por isso fica como plano B.

## 3. Atualização em ondas

- **A casa do Herlon no canal Beta**, atualizando sozinha pelo caminho normal ("Atualizar" lendo as releases),
  e não mais por `bin/deploy-local`. É o piloto do que o cliente vai receber.
- **Clientes no canal Estável**, atualizando sozinhos na janela da madrugada. A estável só sai quando a beta
  passou 48 h na casa do Herlon (já é a regra do `promover-estavel.yml`).
- **Freio**: o sinal de vida recebe da central a versão mais nova liberada. Se uma estável der problema, o
  Herlon segura na central e nenhum cliente atualiza para ela até liberar. Quem já atualizou aparece na lista.
- A central mostra quem está em qual versão e quem atualizou ou voltou sozinho (o aviso que já existe no fim de
  toda atualização passa a ir também no resumo).

## 4. Backup de todos os clientes

- Destino padrão do integrador: **SSH na VPS, uma pasta por cliente**, cifrado com a senha de backup de cada
  instalação (`BACKUP_PASSPHRASE`, guardada no vault do `minha-infra`; nunca no repo). O Google Drive do cliente
  continua possível onde ele preferir.
- O teste de restauração semanal que já existe passa a contar no resumo: a central avisa se falhar.
- **Restaurar noutro hardware**: runbook curto e testado (servidor novo → `install.sh` → restaurar a cópia mais
  nova → aparelhos de volta). Teste de aceite: restaurar a casa do Herlon num segundo equipamento.

## Fora desta proposta (próximas)

- Acesso remoto padronizado por cliente e o acesso de técnico do integrador em todas as instalações (item 4 da
  conversa de 24/11).
- Confirmação real em todos os drivers e recuperar horário perdido depois de queda (item 1).
- Descoberta automática na instalação e receitas prontas (item 5).

## Etapas

1. **Temperatura e "ficou sem rede"** como métricas do Sistema e verificações de Saúde (vale já para a casa).
2. **Sinal de vida** (`Integrator::Report` + job) com fila local quando a rede cai.
3. **Central** na instância da VPS: lista, página do cliente, avisos.
4. **Freio de versão** e a casa do Herlon no caminho normal de atualização (canal Beta).
5. **Backup do integrador** (SSH na VPS) e o teste de restauração noutro equipamento.

## Teste de aceite

- Desligar a rede do servidor da casa por 20 min: a central avisa "sem sinal" em até 15 min e, quando volta,
  "voltou depois de 20 min"; o resumo guardado chega.
- Forçar temperatura (limite baixo de teste) e disco: a central avisa e depois mostra o "voltou".
- Segurar uma versão na central: um servidor de teste no canal Estável não atualiza para ela.
- Restaurar a cópia mais nova da casa num segundo equipamento e abrir o painel com os aparelhos.

## Andamento

- 24/11/2026: etapa 1 no ar na casa (`ServerVitals`, `ServerWatchJob`, verificação "Servidor" da Saúde). Etapas 2 e
  3 e o freio no código (`Integrator`, `Integrator::Report`, `Integrator::Watch`, `Installation`, `/integrador`,
  `POST /api/v1/integrador/resumo`, `Updates::Auto.held?`). Falta subir a instância da central na VPS (compose,
  Caddy, DNS, segredos no vault) e ligar a casa nela (`INTEGRATOR_URL`/`INTEGRATOR_TOKEN`).
- Fora por enquanto: o aviso "versão atrás da estável há mais de 7 dias" (pede a central consultar as releases).

