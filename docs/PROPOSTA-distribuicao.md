# Proposta: distribuição do Minha Automação

Aprovada em 03/11/2026. Objetivo: o MA se instala e se mantém sozinho, como o
Home Assistant (HAOS, Container, imagem de VM), sem depender do
desenvolvedor.

## Onde estávamos

| Item | Estado em 03/11/2026 |
|---|---|
| Release | Tag `vX.Y.Z` à mão → imagem `:vX.Y.Z` + `:latest-stable` + release. Só existia a `v0.9.0` |
| Atualizar | Botão em Configurações → Sistema (backup, troca, volta sozinho). Testado |
| MA Docker | `install.sh` de um comando (Debian, Ubuntu, Raspberry Pi OS) |
| MAOS / ISO | Só o roteiro em `docs/instalacao.md` |

## Bloqueios (valem para todas as formas)

1. **Imagem privada**: o pacote do GHCR herda a visibilidade do repo. Decisão:
   deixar o **pacote público** agora (o código abre depois). É um clique do
   dono da organização (GitHub → Packages → minha-automacao → Change
   visibility); não há API.
2. **Só amd64**: o runner da WSL usa podman sem buildx. Decisão: **arm64 no
   próprio runner da WSL**, por emulação (qemu-user-static + `podman build
   --platform linux/arm64` e `podman manifest`), aceitando o build mais
   lento. Sai num job à parte, depois do amd64, para não atrasar o deploy.
3. **Imagens `:local`** (`homekit-bridge`, `flasher`, `matter-bridge`): passam
   a ser construídas e publicadas pelo CI em `ghcr.io/minhasuite/…`.

## Etapas

### 1. Bloqueios
Pacote público, imagem multi-arquitetura (amd64 + arm64) e as três imagens
auxiliares no GHCR.

### 2. Release e atualização automáticas (feita nesta proposta)
- **Beta a cada master verde**: `vX.Y.Z-beta.N` (próximo patch da última
  estável + contador), imagem `:vX.Y.Z-beta.N` + `:latest-beta` e uma
  pré-release com as notas desde a anterior.
- **Estável toda segunda** (`promover-estavel.yml`, 10h de Brasília): a beta
  mais nova publicada há 48 h vira `vX.Y.Z` (mesmo commit) e o CI/CD da tag
  publica `:vX.Y.Z` + `:latest-stable` e a release. Manual pelo Actions, com
  a beta e a idade mínima como entrada. Mudança grande = tag `vX.Y.0` à mão.
- **Canal por servidor** (Configurações → Sistema): Estável ou Beta. A casa do
  Herlon fica no Beta (piloto).
- **Atualizar sozinho**: janela de 2 h (padrão 3h–5h), estável só com 2 dias
  de publicada, beta na hora; usa o mesmo `bin/ma-update` (backup, troca, volta
  sozinho). Versão que voltou ou falhou não é tentada de novo sozinha.
- **Aviso** a dono e administradores no fim de toda atualização (sozinha ou
  pelo botão).
- **Comparação de versões**: beta abaixo da estável do mesmo número; quem roda
  `X.Y.Z-beta.N` não "atualiza" para a `X.Y.Z` (é uma beta anterior
  promovida, e voltar código pode desfazer migração).

### 3. Imagem x86 e de VM, depois a ISO
- Base Debian mínima gerada por script (mkosi), com Docker, as imagens do
  compose já carregadas, `avahi` (`minha-automacao.local`) e o serviço de
  primeiro boot que gera os segredos (nunca na imagem).
- Saídas por release: `.img.xz` (mini PC, gravar no SSD), `.qcow2` (Proxmox)
  e `.ova` (VirtualBox/VMware), com SHA-256.
- ISO: Debian que se instala sozinho (preseed) e sai igual à imagem.
- Atualização do sistema: `unattended-upgrades` do Debian; a do MA, pela tela.

### 4. Raspberry Pi (depende do arm64)
- `pi-gen` com um estágio do MA, `.img.xz` para Pi 4/5 e um JSON de
  repositório para o Raspberry Pi Imager.

### Depois (fora agora)
- Sistema imutável com duas partições e atualização atômica (Buildroot +
  RAUC, como o HAOS): só se a base Debian der problema de manutenção.

## Teste de aceite

- Etapa 2: um master verde gera a beta; a casa (canal Beta, sozinho ligado)
  atualiza na janela e o push avisa; a promoção cria a estável e um servidor
  no canal Estável a recebe dois dias depois.
- Etapas 3 e 4: gravar, ligar sem teclado, abrir pelo `.local`, passar a
  primeira configuração e atualizar pela tela para a próxima versão.
