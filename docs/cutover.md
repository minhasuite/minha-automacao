# Troca do Home Assistant (cutover)

Roteiro para tirar a instalação da sombra e desligar o sistema antigo. Vale
para qualquer instalação migrada pelo F10 (`docs/migracao.md`); os exemplos
falam do Home Assistant porque é a fonte de referência que existe hoje.

## 1. Pré-checagens automáticas

Na tela: **Configurações → Saúde → Pronto para a troca** (administradores).
No servidor:

```bash
docker compose exec worker bin/rails cutover:check   # sai com 1 se faltar algo
```

| Requisito | Passa quando |
|---|---|
| Sombra sem divergência por N dias | Há comparações cobrindo os últimos `CUTOVER_SHADOW_DAYS` (padrão 7), a mais nova tem até 2 dias e nenhuma na janela tem "Diferente", "MA a mais" ou "MA a menos" |
| Integrações conectadas | Nenhuma integração "Com erro" ou "Aguardando login" |
| Backup fora de casa e teste de restauração | Cópia externa das últimas 26 h e teste de restauração ok nos últimos 8 dias (`docs/backup.md`) |
| App do celular instalado | Pelo menos um celular registrado pela integração "App do celular" |
| Push chegando aos administradores | Algum dono/administrador com aparelho do app visto em 30 dias ou navegador inscrito no Web Push |

Requisito novo = uma linha em `Cutover::REQUIREMENTS` (`app/services/cutover.rb`).
Além da lista, o resto da tela de saúde deve estar sem erro (fila, disco,
aparelhos sem sinal).

Também confira à mão, no relatório da sombra, as automações "Sem par no MA"
(o que o HA faz e ninguém importou) e as que ficaram "COM PERDA" na
importação.

## 2. Ordem da troca

Escolha um horário calmo (de dia, com alguém em casa) e anote a hora de cada
passo.

1. **Backups**: backup completo do HA (Configurações → Sistema → Backups) e,
   no servidor do MA, `bin/rails runner 'Backups.offsite!(force: true)'`.
2. **Lista do que está ligado no HA**: guarde a lista de automações ligadas
   (`GET /api/states`, `automation.*` com `on`) para o rollback.
3. **HA: desligar as automações** (todas as que foram importadas; deixe só as
   de infraestrutura do próprio HA, se houver). A partir daqui o HA não age.
4. **HA: liberar os aparelhos de conexão única**: desative a integração
   LocalTuya (e outras locais com sessão única). O `xiaomi_home` pode ficar
   (o MA fala miIO local sem girar o token).
5. **MA: ligar a escuta local** nos aparelhos Tuya (`listen` na página do
   aparelho, ou em lote no console) e conferir na tela de saúde que os pontos
   voltaram com sinal.
6. **MA: sair da sombra**: Automações e cenas → Sombra → tirar o local da
   sombra (e Configurações → Sistema → desligar a sombra da instalação, se
   estiver ligada). Automações com a marca própria de sombra continuam nela:
   revise a lista.
7. **Alexa**: vincule a skill Smart Home do MA, exponha os pontos
   (`docs/alexa-skill.md`) e só então desvincule a do HA. Teste uma lâmpada
   comum pela voz (nada de portão, fechadura ou sirene).
8. **Celular**: abra o app do MA, confira o push de uma notificação real do
   sistema (não mande push de teste para o celular de outra pessoa).
9. **Observar 24 a 48 h**: tela de saúde, Alertas, execuções com falha
   (Automações → Execuções) e o diário dos aparelhos críticos.

## 3. Como voltar (rollback)

Leva minutos e não perde dado do MA (o histórico continua sendo gravado).

1. **MA de volta em sombra**: local (ou a instalação inteira). Nada mais
   comanda aparelho, avisa ou fala.
2. **MA: desligar a escuta local** dos aparelhos Tuya (libera a conexão única).
3. **HA: reativar** a LocalTuya e ligar de novo as automações da lista do
   passo 2.
4. **Alexa**: revincular a skill do HA, se ela foi desvinculada.
5. Anotar o motivo na issue da troca e corrigir no MA (em sombra) antes de
   tentar de novo; a pré-checagem volta a contar os N dias.

## 4. O que desligar no HA (depois de 7 dias estáveis)

- Automações e scripts importados (já desligados no dia da troca).
- Integrações que o MA assumiu: LocalTuya/Tuya, Alexa Media Player
  (`alexa_media`), câmeras/DVR, MQTT, agendas, app do celular do HA
  (`mobile_app`: desinstale o app do HA para não receber aviso em dobro).
- Exposição para assistentes (Nabu Casa / skill do HA).
- Backups automáticos do HA (o MA tem os dele, com cópia fora de casa).
- Por fim a máquina do HA: desligue, guarde o último backup completo por 30
  dias e só então reaproveite o hardware.

## 5. Depois da troca

- A comparação da sombra perde o sentido: remova a integração "Home
  Assistant (migração)" (o token de leitura do HA deixa de existir).
- Revise os alertas de saúde: eles passam a ser o único aviso de que algo
  parou (integração com erro, fila parada, backup externo atrasado).
