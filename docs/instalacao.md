# Instalação, atualização e imagem pronta

## Instalar (um comando)

Numa máquina com **Debian 12+, Ubuntu 22.04+ ou Raspberry Pi OS 64 bits**
(Raspberry Pi 4/5 com 4 GB ou mais, mini PC x86_64), com acesso à internet:

```bash
curl -fsSL https://raw.githubusercontent.com/minhasuite/minha-automacao/master/install.sh | sudo bash
```

O `install.sh` (na raiz do repo, versionado):

1. confere o sistema e o processador (64 bits);
2. instala o Docker pelo `get.docker.com` se faltar (com o plugin Compose);
3. baixa a imagem (`MA_TAG`, padrão `latest-stable` = última versão numerada),
   cria `/opt/minha-automacao` e tira o `docker-compose.local.yml` de dentro da
   imagem como `docker-compose.yml` (o mesmo que a atualização faz; não depende
   do repositório);
4. gera os segredos **na própria máquina** (`.env`, `chmod 600`): `SECRET_KEY_BASE`,
   senhas do banco e do MQTT, chaves do Active Record Encryption, `SUPERVISOR_TOKEN`,
   par VAPID do Web Push; grava `APP_HOST` (IP da máquina), `WEB_PORT` e `IMAGE`;
5. baixa as imagens, sobe o compose e espera o `/up`;
6. mostra o endereço: abrir no navegador leva à **primeira configuração**
   (conta do dono → casa → descoberta → áreas → painel → família e app).

Rodar de novo é seguro (não troca segredo nem apaga dado). Variáveis opcionais:
`MA_DIR`, `MA_TAG` (padrão `latest-stable`; ex.: `v0.9.0`), `MA_PORT` (padrão 80),
`MA_IMAGE` (repositório da imagem). Imagem já carregada na máquina (`docker load`,
sem internet, como no roteiro da imagem pronta) também serve: o instalador, o
supervisor e o `bin/ma-update` usam a local quando o registro não responde.

**Acesso ao GHCR (o 403 do `sha-*`)**: o pacote `ghcr.io/minhasuite/minha-automacao`
herda a visibilidade do repositório, que é **privado**; pull anônimo responde
`unauthorized`/403 (conferido em 2026-11-02, inclusive no `sha-<sha>` de um deploy
antigo). Para vender, o dono da organização precisa deixar o **pacote público**
(GitHub → organização → Packages → minha-automacao → Package settings → Change
visibility → Public; não há API para isso). O código continua privado; só a
imagem fica legível. Enquanto isso, a máquina precisa de `docker login ghcr.io`
com um token `read:packages` antes do `install.sh` (não recomendado para cliente:
o token fica na máquina), e o supervisor não manda credencial no pull (a
atualização pela tela só funciona com pacote público ou imagem já carregada).
O `install.sh` em si e as releases também estão no repo privado: publicar o
script num endereço público (ex.: `https://get.minhasuite.com/automacao`) e pôr
`UPDATE_TOKEN` (leitura de releases) no `.env` até o repo/espelho de releases
ser público. O `bin/deploy-local` continua sendo o caminho do desenvolvedor
(imagem enviada pelo SSH, sem GHCR).

**Testado em máquina limpa** (2026-11-02, containers com systemd e Docker dentro,
no lugar de VMs): Debian 13 e Ubuntu 24.04 — Docker instalado pelo script,
`/up` 200, raiz → `/primeira-configuracao` ("Crie a conta do dono"); atualização
pela rota do supervisor de uma versão para a seguinte (`done`) e para uma versão
que não sobe (`rolled_back`, `/up` 200 na anterior).

## Atualizar (um clique)

Configurações → Sistema → **Atualização** mostra a versão instalada (a tag da
imagem em `IMAGE` e o commit em `APP_VERSION`) e a mais nova publicada.

- **Fonte das versões** (`Updates::SOURCES`, registro): hoje as releases do
  GitHub (`UPDATE_REPO`, padrão `minhasuite/minha-automacao`; `UPDATE_TOKEN`
  se o repo for privado). A tag da release é a tag da imagem no GHCR. Fonte
  nova (GHCR direto, servidor próprio) = módulo com `key` e `latest` + nome em
  `SOURCES`.
- **Canais (distribuição, `docs/PROPOSTA-distribuicao.md`)**: todo master
  verde vira uma **beta** `vX.Y.Z-beta.N` (pré-release + imagem
  `:vX.Y.Z-beta.N` e `:latest-beta`); toda segunda às 10h o
  `promover-estavel.yml` promove a beta mais nova com 48 h a **estável**
  `vX.Y.Z` (mesmo commit; o CI/CD da tag publica a imagem e a release). Em
  Configurações → Sistema o dono escolhe o canal (Estável/Beta, em
  `storage/update-settings.json`, por servidor) e liga **Atualizar sozinho**:
  o `UpdateAutoJob` (a cada 15 min) atualiza na janela de 2 h escolhida,
  estável só com 2 dias de publicada, e não repete sozinho a versão que voltou
  ou falhou. O fim de toda atualização vira aviso para dono e administradores.
  Quem roda `X.Y.Z-beta.N` não "atualiza" para a `X.Y.Z` (beta anterior
  promovida): espera a próxima estável.
- **Publicar uma versão à mão** (mudança grande, `vX.Y.0`): `git tag -a v1.2.0 -m "Resumo da versão" && git push
  origin v1.2.0`. O CI (`ci-cd.yml`) roda a qualidade, constrói a imagem com a
  versão gravada (`RELEASE_TAG`), publica `:v1.2.0` e `:latest-stable` e só
  então cria a release `v1.2.0` (notas = mensagem da tag + commits desde a tag
  anterior). Sem deploy na VPS (o master continua publicando `:latest`/`:sha-*`
  e fazendo o deploy da demonstração). Só tags `vX.Y.Z` disparam.
- A versão instalada mostrada é a `RELEASE_TAG` da imagem (ou a tag de `IMAGE`
  em imagens do master): quem instalou `latest-stable` não vê "atualização
  disponível" da própria versão.
- **Atualizar agora** (só o dono) → `POST /system/update` no supervisor, que
  baixa a imagem e cria um container à parte (`docker:27.5-cli`, com o socket do
  Docker e a pasta do compose no mesmo caminho) rodando o `bin/ma-update`:
  1. backup do banco (`backups/antes-da-atualizacao-<data>.sql.gz`);
  2. baixa a imagem nova e pega o `docker-compose.local.yml` de dentro dela
     (o atual fica em `backups/docker-compose-<data>.yml`);
  3. troca `IMAGE=` no `.env` e sobe o compose;
  4. espera o `/up` por até 5 minutos; se não responder, volta o compose e a
     imagem anteriores; se nem assim subir (migração já aplicada), restaura o
     backup do banco e sobe a anterior.
  O andamento fica em `backups/update-status.json` (`state`: running, done,
  rolled_back, failed; `step`: backup, pull, restart, rollback); a tela lê em
  `/backups` e recarrega sozinha enquanto roda.
- Por que um container à parte: o `docker compose up` recria o próprio
  supervisor; o atualizador não pode morrer junto.
- Sem supervisor (VPS de demonstração) a seção mostra só a versão.

**Voltar à mão** (se a tela disser que falhou): na pasta do servidor,
`sed -i 's#^IMAGE=.*#IMAGE=<imagem anterior>#' .env && docker compose up -d`;
o compose anterior está em `backups/docker-compose-<data>.yml` e o banco em
`backups/antes-da-atualizacao-<data>.sql.gz`
(`gunzip -c ... | docker compose exec -T db psql -U minha_automacao minha_automacao`
num banco recriado).

## Imagem pronta para Raspberry Pi / mini PC (roteiro)

Objetivo: gravar o cartão/SSD, ligar e abrir `http://minha-automacao.local`.
Ainda não há imagem publicada; o caminho é este:

1. **Base**: Raspberry Pi OS Lite 64 bits (Pi 4/5) ou Debian 12 netinst (mini PC).
2. **Construção** com `pi-gen` (Pi) ou `debootstrap`/Packer (x86): um estágio
   extra que instala o Docker, copia o `install.sh` para
   `/usr/local/sbin/minha-automacao-install` e um serviço systemd de primeiro
   boot (`ConditionPathExists=!/opt/minha-automacao/.env`) que roda o instalador
   com `MA_TAG=<versão da imagem>` e se desliga. Segredos nascem no primeiro
   boot, nunca na imagem.
3. **Imagens do Docker já dentro**: `docker save` das imagens do compose no
   estágio de build e `docker load` no primeiro boot (liga sem internet; a
   atualização depois é pela tela).
4. **Rede e nome**: hostname `minha-automacao`; o serviço `mdns` do compose já
   anuncia `_minhaautomacao._tcp` para o app achar o servidor, e o
   `avahi-daemon` do sistema responde `minha-automacao.local`.
5. **Publicação**: `.img.xz` por versão nas releases do GitHub, com SHA-256;
   gravação pelo Raspberry Pi Imager (JSON de repositório próprio) ou balenaEtcher.
6. **Teste de aceite**: gravar, ligar sem teclado, abrir pelo `.local`, passar a
   primeira configuração, atualizar pela tela para a próxima versão.
