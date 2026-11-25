# Revisão de segurança — F8

Data: 25/11/2026. Escopo: tudo o que existe das fases F0 a F7, sem commit (só o commit inicial no
repositório). Revisão só de leitura: nenhum código foi alterado.

Revisado: `server/` (directd e `direct-admin`), `app/lib/`, `app/android/`, `app/ios/`, contra
`docs/protocolo.md`, `docs/ameacas.md` e `docs/PLANO.md` (seções 5, 6, 8, 9, 9.1, 10 e 15).

Severidade:
- **Crítico:** quebra o sigilo ou a autenticidade sem condição especial.
- **Alto:** quebra uma garantia do modelo de ameaças, ou falta uma defesa que ele dá como existente.
- **Médio:** enfraquece uma defesa; exige condição extra (aparelho na mão, servidor hostil, outro app).
- **Baixo:** defesa em profundidade, robustez ou divergência pequena da spec.

Referências `arquivo:linha` são relativas à raiz do repositório.

## Status das correções

Aplicadas em 25/11/2026, sem commit. O corpo do relatório, abaixo, descreve o código **antes** das
correções (as linhas citadas são as daquela versão).

| Id | Status | O que foi feito / motivo |
|----|--------|--------------------------|
| S1 | corrigido, com resto | Código do aparelho na CLI e em Ajustes (protocolo 13.4); duas confirmações; só conversas com alguma época assinada que inclua aparelho do usuário em `recipients` (delas, todas as épocas, inclusive as criadas enquanto ele estava sem aparelho); lista de conversas antes de gravar. Resto: a ligação aparelho→usuário e a `sign_pub` do criador vêm do banco, e quem reescrever as duas engana o filtro; a lista é a última conferência Grupos (G-B): filtro pela cadeia verificada, `protocolo-grupos.md` §5.4; a regra por conversa não vale para eles. |
| A1 | corrigido | Tabela `seen_keys` (banco v4) e aviso local "conectou/desconectou um aparelho". Numa instalação nova, aparelho antigo do contato visto só no histórico também avisa, com a data antiga. Não avisa sobre aparelho novo na conta do próprio usuário (§7.3 fala em contatos) É pré-requisito para liberar grupos (`protocolo-grupos.md` §12). |
| S2 | corrigido | 5 perfis/min por aparelho; `directory_changed` no máximo 1 a cada 3 s por conexão |
| S3 | corrigido | `challenge` só por IP; `verify` por (IP, aparelho). Cobrar só após desafio válido não bastaria: o desafio de qualquer aparelho é de graça |
| S4 | corrigido | `LockWraps` na criação de época; app busca `epochs/mine` do zero uma vez por sessão ao faltar chave |
| S5 | corrigido em parte | Cota de 1 GiB por usuário/dia; download limitado (120/min por aparelho, 4 por usuário, 16 no total); `direct-admin media prune`. Pendente: órfão seguido de outra mensagem do mesmo aparelho não é apagado (o servidor não vê o `blob_id`; exigiria mudar o protocolo) |
| S6 | corrigido | Ao refazer o `LISTEN`, o `directd` reconfere os aparelhos conectados. Sem teste: exige derrubar a conexão do `LISTEN` |
| S7 | corrigido em parte | 30 criações de época por minuto por aparelho. Pendente: conversas, histórico, diretório e `epochs/mine` (um limite mal dimensionado quebra a sincronização inicial) |
| S8 | corrigido | O instalador marca `deploy/data/directd/admin.log` com `chattr +a` (o `directd` não tem a capacidade de desmarcar). Resto: quem controla o `directd` ainda acrescenta linhas falsas, root no host desfaz a marca, e o `escrow rewrap` registra no notebook do moderador. Sem syslog remoto |
| S9 | aceito | Registrado em `ameacas.md` §2 como risco que sobra; assinar o pedido muda o protocolo |
| S10 | corrigido | Convite com `--ttl` de no máximo 7 dias |
| S11 | corrigido | `DIRECT_TRUSTED_PROXY=cloudflared`: o cabeçalho só vale se a conexão vem do endereço desse nome na rede do compose; sem a variável o cabeçalho é ignorado |
| A2 | corrigido | Membros fixados na primeira vez; troca recusada com aviso na conversa Em grupos, resolvido pela cadeia assinada (`protocolo-grupos.md` §2.7); no 1:1 segue a fixação. |
| A3 | corrigido | Atraso exige relógio de parede e monotônico; relógio voltado ou reinício recomeça a espera. No iOS `systemUptime` não conta o repouso (espera pode ficar maior). Apagar tudo após N erros: não feito, é decisão de produto |
| A4 | corrigido, sem verificação completa | `accessibilityDataSensitive` na `FlutterView` (API 34+) e recusa de teclado de terceiros no iOS. Não conferido com um serviço de acessibilidade comum nem com TalkBack; iOS não compilado. Área de transferência: aceito, registrado em `ameacas.md` §7 |
| A5 | corrigido | `allowBackup="false"`, `fullBackupContent="false"` e `data_extraction_rules.xml` |
| A6 | corrigido | Marca de instalação gravada só depois da limpeza |
| A7 | corrigido | `sodium.memcmp` (sem teste: tempo constante não é testável aqui) |
| A8 | corrigido | EXIF usa os ids locais; resposta diferente é recusada |
| A9 | corrigido | O release exige `app/android/key.properties` e nunca usa a chave de debug; sem o arquivo o build para (`docs/apk.md`). A chave em si o dono cria |
| B1 | corrigido | Tranca ao desligar a tela e após 5 min sem interação (`bubbleIdleTimeout` em `app_controller.dart`), contados no relógio monotônico. Depois, a bolha pede a trava do app e então a da conversa (duas autenticações, D7) |
| B2 | corrigido em parte | Com a interface trancada a ponte só serve conversa com bolha; chave errada pela ponte não desliga a digital. Aceito: `bioInvalidated` segue desligando a digital (só isolates do próprio processo alcançam; negação de serviço) |
| B3 | corrigido | `prune` pede a tranca das bolhas que sumiram (nativo, sem teste automático) |
| B4 | aceito | De acordo com o PLANO 9.1 |
| B5 | aceito | `PendingIntent` mutável é exigência do Android; componente explícito |

Verificação das correções (25/11/2026): `go vet` e `go test -race ./...` com Postgres;
`flutter analyze` e `flutter test`; `e2e_test.dart` contra o `directd` corrigido. No emulador API 34:
bolha trancada ao desligar a tela e após 5 minutos parada com a tela ligada. No API 35: trancada ao
desligar a tela, e conversa trancada depois de "Forçar parada" (B3). Os emuladores usaram senha;
digital, aparelho real, build de release e iOS não foram conferidos.

## Resumo

Nenhum achado crítico. Os pontos que pedem correção antes da F9:

| Id | Sev. | Onde | Problema |
|----|------|------|----------|
| S1 | alto | `direct-admin escrow rewrap` | Confia em `kex_pub` e em membros vindos do banco: invasor do servidor lê histórico |
| A1 | alto | app, diretório | Aviso de aparelho novo (§7.3) não foi implementado |
| S2 | médio | `PUT /v1/me/profile` | Sem limite; cada chamada vai a todas as conexões e derruba quem tem fila cheia |
| S3 | médio | `/v1/auth/*` | Limite por `device_id` antes da prova: qualquer um tranca o login de outro aparelho |
| S4 | médio | criação de época | Cursor `wrap_id` pode pular embrulho; app fica sem a chave para sempre |
| S5 | médio | blobs | Sem cota, sem limite no download, blob inteiro em memória |
| A2 | médio | app, conversas | Membros da conversa vêm do servidor e podem ser trocados |
| A3 | médio | app, trava | Atraso entre senhas erradas burlável mudando o relógio |
| A4 | médio | app, Android/iOS | `accessibilityDataSensitive` e recusa de teclado no iOS não existem |
| A5 | médio | app, Android | Backup automático leva banco e preferências |
| B1 | médio | bolha | Decisão: trancar a bolha sozinha (recomendação: 5 min e ao desligar a tela) |

O restante é baixo. Itens conferidos sem achado estão no fim.

## Achados do servidor e da CLI

### S1 (alto) — `escrow rewrap` sela com `kex_pub` e membros que vêm do banco

`server/cmd/direct-admin/escrow.go:203-204` sela a chave de cada época com `devices.kex_pub` lido
do banco. `server/internal/store/admin.go:256-268` (`PendingEscrowEpochs`) escolhe as épocas por
`conversation_members` atual do usuário, sem conferir se algum aparelho dele estava nos
`recipients` assinados pelo criador.

Cenário: quem invadiu o servidor (`ameacas.md` §3) troca o `kex_pub` do aparelho novo que o
moderador vai reembrulhar, ou acrescenta o usuário como membro de conversas alheias. Quando o
moderador roda um `rewrap` legítimo no notebook, a CLI abre as chaves de época com o escrow e as
sela para uma chave do invasor. O invasor passa a ler o **histórico**, que `ameacas.md` §3 diz que
ele não consegue ler. Conferir o certificado não resolve: nesse cenário a chave de assinatura do
servidor também está na mão do invasor.

Correção:
- Antes de selar, a CLI mostra a impressão digital de `sign_pub` e `kex_pub` do aparelho (por
  exemplo, 20 dígitos como em §4.3), e o moderador confere com o mesmo código exibido em Ajustes
  no aparelho novo, por outro canal (pessoalmente ou por telefone). O app precisa exibir esse
  código.
- Reembrulhar só épocas cujo `recipients` assinado tenha algum aparelho do usuário, ou de que ele
  era membro segundo dados assinados. Épocas de conversas em que ele nunca esteve ficam de fora.
- Listar as conversas que serão reembrulhadas e pedir confirmação.

### S2 (médio) — `directory_changed` sem limite derruba conexões

`server/internal/server/directory.go:137` chama `hub.directoryChanged` a cada
`PUT /v1/me/profile`, que não tem limite de taxa. `server/internal/server/hub.go:124` envia o quadro
a **todas** as conexões, e `hub.go:39` fecha com 4029 quem estiver com a fila de 64 cheia.

Cenário: um membro dispara centenas de `PUT /v1/me/profile` por segundo. Cada quadro chega a todos;
as filas enchem, as conexões caem com 4029, os apps reconectam e caem de novo. A organização fica
sem chat enquanto durar.

Correção: limite por aparelho em `handleProfile` (por exemplo 5 por minuto) e agregar
`directory_changed` (no máximo um por conexão a cada poucos segundos) antes de enfileirar.

### S3 (médio) — Bloqueio do login de outro aparelho

`server/internal/server/auth.go:88` (`challenge`) e `auth.go:127` (`verify`) consomem o balde
`authDev` (10 por minuto, `server.go:59`) pelo `device_id` que o chamador informa, antes de qualquer
prova. Os `device_id` são públicos para membros (`/v1/directory`).

Cenário: um membro, ou qualquer um que conheça o id, manda 10 `challenge` por minuto com o id da
vítima (abaixo do limite de 30 por IP). A vítima recebe `rate_limited` ao renovar o token e fica
sem chat em até 15 minutos, enquanto o ataque durar.

Correção: em `challenge`, limitar só por IP. Em `verify`, cobrar `authDev` só depois de achar um
desafio válido para aquele aparelho; ou indexar o balde pelo par (IP, aparelho).

### S4 (médio) — Corrida no cursor `wrap_id`

`server/internal/server/epochs.go:183-184` insere embrulhos com `wrap_id` de `bigserial` sem
`store.LockWraps`, que só o `rewrap` usa. O comentário de `server/internal/store/admin.go:235-238`
explica por que isso importa: o `wrap_id` é o cursor do cliente.

Cenário: épocas novas em duas conversas ao mesmo tempo, ambas com o aparelho D. A transação A
pega `wrap_id` 10, a B pega 11, B faz commit antes. D chama `GET /v1/epochs/mine` e avança o
cursor para 11. A faz commit depois e o 10 nunca é baixado. O app também avança o cursor pelo
`wrap_id` do evento `epoch` ao vivo (`app/lib/chat/chat_service.dart:444`). As mensagens daquela
época ficam em "Aguardando chave" para sempre: o app não volta a sincronizar do zero.

Correção: `store.LockWraps` (ou `pg_advisory_xact_lock`) em `handleCreateEpoch`. No app, como
defesa extra, ao receber mensagem de época sem chave, buscar `epochs/mine` de novo a partir de 0
(uma vez por sessão).

### S5 (médio) — Blobs sem cota e carregados inteiros em memória

`server/internal/server/media.go:64` (upload) e `media.go:112` (download).
- Upload: 20 por minuto de até 10 MiB por aparelho, sem cota nem limpeza de órfãos. Um aparelho
  enche o disco em horas.
- `GET /v1/blobs/{id}` não tem limite de taxa e lê o blob inteiro para memória. Cem downloads em
  paralelo usam cerca de 1 GiB.

Correção: cota por usuário (por exemplo 1 GiB por dia), limpeza de órfãos pela CLI, limite de taxa
e semáforo de concorrência no download.

### S6 (baixo) — Revogação no WebSocket depende só do `NOTIFY`

`server/internal/server/ws.go:213-223` e `hub.go:100`. Se a conexão `LISTEN` cair, a reconexão
leva 2 s ou mais e um `pg_notify` de revogação nesse intervalo se perde. O WebSocket do aparelho
revogado fica aberto até o token vencer (no máximo 15 min) e recebe `message` por push. Impacto:
só metadados e texto cifrado; o envio seguinte já força época nova sem ele
(`server/internal/server/messages.go:104`). Correção: ao reconectar o `LISTEN`, reconferir o
estado de todos os aparelhos conectados.

### S7 (baixo) — Rotas autenticadas sem limite de taxa

Criação de época (`server/internal/server/epochs.go:46`), conversas, histórico, diretório e
`epochs/mine` não têm limitador. Um membro cria época a cada 100 ms e o par recebe
`epoch_required` em todo envio. Correção: limitadores por aparelho nessas rotas.

### S8 (baixo) — Registro de comandos não é só de acréscimo

`server/cmd/direct-admin/main.go:194-202` abre o arquivo com `O_APPEND`, o que não impede
reescrita. No `server/Dockerfile` (`DIRECT_ADMIN_LOG=/data/admin.log`) o arquivo fica no volume do
`directd`, gravável pelo mesmo usuário do processo exposto à rede. Os comandos `escrow` rodam no
notebook e gravam em `~/.direct-admin.log`: o registro fica em dois lugares. O conteúdo está certo
(horário, operador, argumentos, id do token; sem semente nem senha). Correção: arquivo fora do
volume do `directd` com `chattr +a` no host, ou syslog remoto; documentar onde fica cada parte.

### S9 (baixo) — Registro de salvamento vale só com o token

`server/internal/server/media.go:174`: quem tem um token de acesso (o Cloudflare, por 15 minutos)
registra salvamentos falsos em nome do usuário e polui a auditoria. `ameacas.md` §2 não cita.
Correção: documentar como risco que sobra, ou assinar o pedido com a chave do aparelho.

### S10 (baixo) — Prazo do convite sem teto

`server/cmd/direct-admin/commands.go:54-60` e `:106` aceitam qualquer `--ttl`; `--ttl 36500d` cria
convite de 100 anos, e um QR vazado segue valendo. Correção: teto de 7 dias.

### S11 (informativo) — Cabeçalho de IP confiado sem conferir a origem

`server/internal/server/server.go:173-178` usa `CF-Connecting-IP` quando
`DIRECT_TRUSTED_IP_HEADER` está ligado, venha a requisição de onde vier. Hoje é seguro, porque o
compose não publica a porta. Se alguém publicar `:8080`, o cabeçalho passa a ser forjável e os
limites por IP caem. Correção: aceitar o cabeçalho só quando `RemoteAddr` for o `cloudflared`.

## Achados do app

### A1 (alto) — Aviso de aparelho novo (§7.3) não existe

`app/lib/chat/chat_service.dart:470` (`_refreshDirectory`) grava certificados novos de contatos em
`known_devices` sem comparar com os `sign_pub` já vistos. Não há nenhum aviso "conectou um aparelho
novo" no app (busca por "aparelho novo", "conectou", `newDevice` não acha nada em `app/lib/`).

Cenário: quem invade o servidor (ou o moderador) cria um aparelho fantasma para João e assina o
certificado com a chave do servidor. O app de Ana vê o aparelho no diretório, o inclui na próxima
época (§9.5) e passa a cifrar para ele. Nada aparece na conversa. O invasor lê todas as mensagens
novas de Ana para João. `ameacas.md` §3 e §5 dão esse aviso como a única mitigação contra o
fantasma.

Correção: implementar §7.3 como está escrito. Guardar, por `user_id`, o conjunto de `sign_pub` já
vistos (tabela nova no banco cifrado). Em `_refreshDirectory` e em `_cert`, ao ver um `sign_pub`
novo de um contato com conversa, inserir na conversa uma linha local "<admin_label> conectou um
aparelho novo em <enrolled_at>"; ao sumir um, "desconectou um aparelho". Na primeira sincronização
de um contato (sem conjunto anterior), só registrar. Teste: diretório muda entre duas chamadas e o
aviso aparece.

### A2 (médio) — Membros da conversa vêm do servidor sem fixação

`app/lib/chat/chat_service.dart:542` (`_upsertConv`) aceita a lista `members` do servidor (de
`GET /v1/conversations` e do evento `conversation`) e grava `peerUserId` com
`insertOnConflictUpdate`, sobrescrevendo o contato de uma conversa que já existe.

Cenário: quem controla o servidor ou o Cloudflare (que termina o TLS) responde que a conversa
Ana–João agora é Ana–Marcos. O app troca o contato da conversa, a próxima mensagem de Ana cria
época para os aparelhos de Marcos (§9.5) e o servidor hostil aceita (o passo 3 de §9.6 é dele).
Ana vê o título mudar, mas o histórico continua ali e é fácil não notar. Marcos lê o que Ana
escrever.

Correção: na v1 (só 1:1) os membros de uma conversa nunca mudam. Gravar os membros na primeira vez
e recusar, com alerta local, qualquer `members` diferente para o mesmo `conversation_id`. Quando
vierem os grupos, a mudança de membros precisa ser assinada por quem a fez.

### A3 (médio) — Atraso entre senhas erradas usa o relógio de parede

`app/lib/core/vault.dart:145` calcula o tempo restante com `DateTime.now()`. O relógio do sistema
é do usuário.

Cenário: alguém com o telefone destravado e o app trancado erra a senha, adianta o relógio do
sistema em 15 minutos em Ajustes e tenta de novo na hora. O limite real passa a ser só o custo do
Argon2id (cerca de 0,5 s a 1 s por tentativa no aparelho). Senha mínima de 8 caracteres
(`app/lib/ui/enroll_screen.dart:8`) com uma lista de senhas comuns cai rápido.

Correção: guardar junto do contador o `elapsedRealtime` (Android, `SystemClock`) ou o
`systemUptime` (iOS) e exigir que tanto o relógio de parede quanto o monotônico tenham andado;
se o relógio voltar ou o uptime for menor que o gravado (reinício), recomeçar a espera inteira.
Considerar apagar tudo após N erros (por exemplo 20), com aviso na tela a partir do décimo.

### A4 (médio) — Mitigações de `ameacas.md` §7 que não existem

- **Acessibilidade (Android 14+):** `accessibilityDataSensitive` não aparece em nenhum lugar.
  `app/android/app/src/main/kotlin/com/nettotech/direct/SecureWindow.kt:29` só liga
  `filterTouchesWhenObscured`. Cenário: app com serviço de acessibilidade concedido lê o texto
  das mensagens na `FlutterView`, inclusive na bolha. Correção: em `applyViews`, na API 34+,
  `view.setAccessibilityDataSensitive(View.ACCESSIBILITY_DATA_SENSITIVE_YES)` na `FlutterView`.
  Conferir que o TalkBack continua lendo (serviços marcados como ferramenta de acessibilidade
  continuam vendo).
- **Teclado de terceiros no iOS:** `app/ios/Runner/AppDelegate.swift:29` não implementa
  `application(_:shouldAllowExtensionPointIdentifier:)`. Cenário: teclado instalado com "acesso
  total" registra tudo o que é digitado no Direct, inclusive a senha do app. Correção: devolver
  `false` para `.keyboard`.
- **Área de transferência:** não há limpeza após cópia explícita. Baixo impacto; registrar em
  `ameacas.md` como risco que sobra ou implementar.

`ameacas.md` §7 lista essas três linhas como mitigação feita. Ou implementa, ou corrige o documento.

### A5 (médio) — Backup do Android leva os dados do app

`app/android/app/src/main/AndroidManifest.xml:12`: `<application>` não define
`android:allowBackup="false"` nem `android:dataExtractionRules`. O padrão é fazer backup.

Cenário: o Auto Backup (Google Drive) e a transferência entre aparelhos copiam o banco SQLCipher
(cifrado), os arquivos de `biometric_storage` e de `flutter_secure_storage` (cifrados com chaves do
Keystore, que não vão junto) e `SharedPreferences` em claro (`installed`, ids das conversas com
bolha). Restaurado num aparelho novo, `installed=true` impede a limpeza de primeira execução e o app
encontra dados que não abre. O texto cifrado e os metadados saem do aparelho, contra o que o
PLANO 15 promete.

Correção: `android:allowBackup="false"` e `android:dataExtractionRules` (API 31+) excluindo
`root`, `file`, `database` e `sharedpref` de `cloud-backup` e `device-transfer`;
`android:fullBackupContent="false"` para API 30.

### A6 (baixo) — Marca de primeira execução gravada antes de apagar o Keychain

`app/lib/main.dart:52` grava `installed=true` antes de `AppController.init` apagar o Keychain
(`app/lib/app_controller.dart:135`). Se o app morrer entre as duas coisas, o Keychain da instalação
anterior nunca é apagado. Correção: gravar a marca depois de `deleteAll`, `bio.delete` e
`wipeDbFiles` terminarem.

### A7 (baixo) — Comparações da chave-mestra fora de tempo constante

`app/lib/app_controller.dart:286` e `:366` comparam a chave-mestra com `listEquals`. Só código no
mesmo processo mede esse tempo, então o risco é pequeno, mas a spec pede tempo constante para
segredos. Correção: `sodium.memcmp`.

### A8 (baixo) — EXIF da cópia salva usa `user_id` e `device_id` da resposta do servidor

`app/lib/chat/chat_service.dart:1049` grava no EXIF os ids que o servidor devolveu em
`POST /v1/media/saves`. Um servidor hostil pode pôr os ids de outra pessoa na foto. O registro no
banco é o que vale, mas o EXIF passa a mentir. Correção: usar `cert.userId` e `cert.deviceId`
locais e recusar a resposta se forem diferentes.

### A9 (baixo) — Assinatura de release com a chave de debug

`app/android/app/build.gradle.kts:36` assina o build de release com `signingConfigs.debug` (padrão
do modelo do Flutter). Fica para a F9, mas precisa estar resolvido antes de distribuir: APK de
release assinado com chave de debug pode ser substituído por outro assinado com a mesma chave
pública conhecida.

## Chat flutuante (F7)

### B1 (médio) — Decisão: bolha aberta mantém a conversa legível sem limite de tempo

`app/lib/app_controller.dart:518` (`background`): com bolha, o app vai para segundo plano com a
chave-mestra em memória e a conversa da bolha legível até alguém fechar a bolha ou tocar em
"Bloquear". Recolher a bolha não tranca nada.

Cenário: o usuário abre a bolha, recolhe, deixa o telefone destravado na mesa. Quem pega o
telefone toca na bolha e lê a conversa inteira (60 mensagens e miniaturas) e responde como o dono.
O mesmo vale horas depois, se o telefone não travar sozinho ou se a pessoa souber o PIN do
sistema.

**Recomendação:** sim, a bolha deve trancar sozinha.
1. **Tela desligada:** ao receber `ACTION_SCREEN_OFF`, trancar a conversa de toda bolha aberta
   (mesma tranca D7, gravada em `chat_meta`). Quem desbloquear o telefone depois encontra a bolha
   pedindo digital. É o caso mais comum de telefone esquecido.
2. **Inatividade: 5 minutos** sem toque na bolha (recolhida ou aberta), com a interface principal
   trancada. Ao vencer, trancar a conversa e, se todas as bolhas estiverem trancadas, chamar
   `lock()`: a chave-mestra sai da memória e a bolha passa a mostrar a trava do app. Com a digital
   ativada, reabrir custa um toque; 5 minutos cobre uma conversa em andamento sem obrigar a
   reautenticar a cada resposta.
3. Contar o tempo no isolate principal (dono das chaves), zerando a cada `load`, `send` ou toque
   repassado pela ponte; não usar só o relógio de parede (ver A3).

Isso também reduz o tempo em que a chave-mestra fica em memória com a interface trancada.

### B2 (baixo) — A ponte da bolha serve qualquer conversa destrancada

`app/lib/bubble/mini.dart:104` (`LocalMiniBackend.load`) e `send` conferem só se a conversa está
trancada, não se ela tem bolha. Com a interface principal trancada, a sessão segue aberta: um
`load` com outro `conversation_id` devolve as mensagens daquela conversa. Hoje só a
`MiniChatActivity` (não exportada, aberta pelo `PendingIntent` da própria bolha) chega até a porta,
e `IsolateNameServer` só é visível dentro do processo; então o risco é baixo. Correção: com
`stage == locked`, recusar `load` e `send` de conversa fora de `c.bubbles`.

Ainda na ponte (`app/lib/bubble/port.dart:45-56`): qualquer isolate do processo (inclusive código
Dart de plugin) pode chamar `bioInvalidated`, que desliga a digital, ou mandar `master` errada a
`unlockApp`, que também desliga a digital (`app/lib/app_controller.dart:293-297`). Só negação de
serviço. Correção: tratar `master` errada como erro sem desligar a digital.

### B3 (baixo) — Tranca perdida quando o processo morre

`app/android/app/src/main/kotlin/com/nettotech/direct/Bubbles.kt:51` (`prune`) tira de `active` as
bolhas cuja notificação sumiu sem pô-las em `dismissed`. Parar o app à força (Ajustes > Forçar
parada) cancela as notificações sem `deleteIntent`. Ao reabrir, a conversa que estava na bolha não
fica trancada. O app inteiro pede senha nesse caso, então o efeito é só perder a tranca D7 daquela
conversa. Correção: em `prune`, mover para `dismissed` tudo o que sai de `active`.

### B4 (baixo) — Atalho de conversa com o nome do contato

`Bubbles.kt:116` publica atalho dinâmico de longa duração com o nome do contato. Atalhos dinâmicos
aparecem ao tocar e segurar o ícone do app no launcher, com o app trancado. `remove` limpa só ao
fechar a bolha. Está de acordo com PLANO 9.1 ("notificação e atalho levam o nome do contato"), mas
vale saber que o nome fica visível fora do app enquanto a bolha existir.

### B5 (baixo, informativo) — `PendingIntent` mutável da bolha

`Bubbles.kt:126`: o `PendingIntent` que abre a bolha é `FLAG_MUTABLE`, exigência do Android para
bolhas. Ele aponta para componente explícito (`MiniChatActivity`) com ação e dados definidos, então
quem o recebe (SystemUI, ouvinte de notificações) só consegue acrescentar extras, que a activity
ignora. O `deleteIntent` e o `contentIntent` são imutáveis. Sem ação.

## Conferido e ok

**Cripto (app e servidor, contra `docs/protocolo.md`)**
- XChaCha20-Poly1305 com nonce de 24 bytes do CSPRNG a cada cifra: mensagem
  (`app/lib/core/chat_crypto.dart:237`), blob (`:282`), cofre local (`app/lib/core/vault.dart`,
  `_seal`).
- App verifica a assinatura antes de decifrar a mensagem e confere certificado e pertença do
  remetente (`app/lib/chat/chat_service.dart`, `_decrypt`); época: certificado do criador,
  pertença, assinatura com a `escrow_pub` fixada, `sealOpen`, compromisso com `sodium.memcmp`
  (`chat_crypto.dart:193`).
- Servidor verifica Ed25519 antes de gravar época e mensagem; embrulho de escrow obrigatório com
  80 bytes; `wraps` igual ao conjunto de aparelhos ativos; envio exige a época atual, então
  aparelho revogado sai na época seguinte.
- Chave aleatória de 32 bytes por imagem; app confere o SHA-256 da mensagem antes de decifrar o
  blob; blob cifrado guardado, nada em claro em disco; temporários do `image_picker` apagados.
- base64url estrito nos dois lados; rótulos de domínio com `0x00` conferem com a spec.

**Servidor**
- Convite: uso único atômico (`UPDATE ... WHERE used_at IS NULL AND expires_at > agora`), TTL e
  `device_ttl` aplicados, assinaturas `invite_sig` e `proof` verificadas
  (`server/internal/server/enroll.go:105`, `:141-149`, `:168`).
- Login: desafio de 32 bytes, preso ao aparelho, 60 s, apagado no uso com sucesso ou falha
  (`auth.go:92-101`, `:136`); `auth_bytes` igual a §6.2; estado do aparelho só depois de
  assinatura válida; prova de revogação assinada.
- Token de 15 min guardado como SHA-256 e buscado pelo hash; estado do aparelho conferido em toda
  requisição (`auth.go:23-55`).
- Revogação apaga tokens e desafios e avisa o hub na mesma transação; WebSocket fechado com 4003.
- WebSocket: primeiro quadro tem de ser `auth` em até 10 s; limite de 64 KiB por quadro; origem
  conferida por padrão; escopo por conversa conferido contra membros.
- IDOR: mensagens, épocas, blobs e `media/saves` conferem pertença; `epochs/mine` filtra pelo
  aparelho; `sender_device_id` e `creator_device_id` têm de ser o aparelho autenticado.
- Corpo JSON até 64 KiB, blob até 10 MiB com `MaxBytesReader`, paginação até 500.
- SQL todo parametrizado; o único `Sprintf` monta o DSN com aspas escapadas (`store.go:49`).
- Log do `directd`: método, caminho sem query, status e duração; sem IP, token ou corpo.

**CLI `direct-admin`**
- `escrow_sk` só é decifrada no processo da CLI; `rewrap` roda no notebook por túnel SSH, como
  descreve `server/README.md`, e confere compromisso e assinatura do criador.
- Senha de escrow com 16 caracteres ou mais, pedida duas vezes; Argon2id t=3, m=256 MiB, com teto
  na leitura; arquivo gravado com `O_EXCL` e modo 0600.
- Semente do convite só no QR e na tela: nem banco nem log.

**App**
- Trava: Argon2id t=3 (`opsLimitModerate`), 64 MiB (`memLimitInteractive`), sal de 16 bytes;
  adequado para celular (acima do mínimo da OWASP) e combinado com o Keystore/Keychain.
- Atraso crescente após 3 erros, de 5 s a 15 min (`app/lib/core/vault.dart:26`), também na bolha;
  só o relógio é fraco (A3).
- "Esqueci a senha" apaga banco, Keychain/Keystore, digital e bolhas (`AppController.wipeAll`).
- iOS: Keychain apagado na primeira execução; itens com `first_unlock_this_device`
  (`app/lib/main.dart:32`).
- SQLCipher: chave derivada da chave-mestra; abrir recusa banco sem SQLCipher.
- Digital: `biometric_storage` 6.0.0-dev.9 com `androidBiometricOnly`/`darwinBiometricOnly`. No
  Android, chave do Keystore com `setUserAuthenticationParameters(0, AUTH_BIOMETRIC_STRONG)`, usada
  por `CryptoObject` (presa ao sensor) e invalidada ao cadastrar digital nova (padrão do Keystore);
  no iOS, `biometryCurrentSet` com `WhenPasscodeSetThisDeviceOnly`. É pré-lançamento: fixar a
  versão e reconferir ao atualizar.
- `FLAG_SECURE` e `setHideOverlayWindows` em `onCreate` da `MainActivity` e da `MiniChatActivity`;
  `filterTouchesWhenObscured` na `FlutterView` de ambas.
- EXIF, ICC e texto removidos no envio (`_encodeClean`); cópia salva com marca d'água e EXIF com
  `save_id`, gravada só depois da resposta do servidor.
- Override HTTP de debug só com `kDebugMode` e host `10.0.2.2` (`app/lib/main.dart:44`);
  `usesCleartextTraffic` só em `src/debug/AndroidManifest.xml`. iOS sem exceção de ATS.
- Prova de revogação verificada com a chave fixada antes de apagar; fechamento 4003 leva a novo
  login, que obtém a prova.
- Campos de texto com `enableIMEPersonalizedLearning: false`.

**F7**
- Ponte por `IsolateNameServer`: só isolates do mesmo processo a enxergam (ver B2 para o que falta).
- `MiniChatActivity`, `BubbleService` e `BubbleDismissReceiver` com `exported="false"`;
  `MainActivity` exportada só como launcher, com `taskAffinity=""`.
- `deleteIntent` imutável grava a tranca em `SharedPreferences` com `commit()` antes de avisar o
  Dart; com o banco fechado, a tranca fica pendente e é aplicada ao abrir. Só falha no caso de B3.
- Notificação da bolha e do serviço sem conteúdo de mensagem; `VISIBILITY_SECRET`; extras e disco
  só com o id da conversa.

## Não verificado

- Testes de integração Go com Postgres (pulados nesta revisão; `go vet` e `go test ./...` passam).
- iOS: nada foi compilado nem rodado (sem Mac).
- Bolha em aparelho real e build de release.
