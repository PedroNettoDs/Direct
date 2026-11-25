# Plano de implantação — Direct

Aplicativo de mensagens em Flutter (Android e iOS) que conversa só com um servidor próprio,
publicado por um domínio no Cloudflare Tunnel. O acesso exige token emitido pelo moderador.
O conteúdo é cifrado ponta a ponta (E2E). O moderador controla usuários e aparelhos e consegue
devolver o histórico a um aparelho novo.

Este documento é a referência para todas as subsessões. Cada fase (seção 12) lê este arquivo
e, a partir da F1, também `docs/protocolo.md`.

---

## 1. Decisões

| ID | Tema | Decisão | Status |
|----|------|---------|--------|
| D1 | Criptografia | Ponta a ponta. Servidor e Cloudflare guardam/transportam só texto cifrado. | Decidido |
| D2 | Servidor | Go: um binário de API (`directd`) e um de administração (`direct-admin`). | Decidido |
| D3 | Notificações | Sem push. Conexão ativa só com o app aberto ou com o chat flutuante aberto. | Decidido |
| D4 | Administração | CLI no servidor. Sem painel web. | Decidido |
| D5 | Recuperar histórico em aparelho novo com E2E | Opção A: escrow organizacional offline. Ver 5.2. | Decidido (24/11/2026) |
| D6 | Banco | PostgreSQL com os dados em `deploy/data/`, na pasta do projeto, fora dos volumes do Docker. Sem LUKS e sem backup periódico. Conteúdo já chega cifrado pelo E2E. Ver seção 11. | Decidido (25/11/2026) |
| D7 | Fechar o chat flutuante | Tranca só aquela conversa. Reabrir, no app ou em pop-up, pede senha ou digital. Ver seção 9. | Decidido (24/11/2026) |
| D8 | Imagens | Envio por câmera ou galeria, cifradas E2E. Salvar na galeria é permitido, com registro no servidor e EXIF de quem salvou. Ver seção 15. | Decidido (24/11/2026) |
| D9 | Digital | Opcional, presa à chave-mestra por chave do Keystore/Keychain. Senha continua como reserva. Ver seção 7. | Proposto |
| D10 | Marca d'água visível nas fotos salvas | Rótulo do usuário + data + `save_id` curto em mosaico na cópia salva, para rastrear vazamento mesmo sem EXIF. Ver seção 15. | Decidido (24/11/2026) |
| D11 | Grupos: mensagens de quem perdeu o acesso | Num grupo, as mensagens de um membro só ficam legíveis enquanto ele tem aparelho válido. Se esquecer a senha, for revogado ou expirar, as mensagens dele aparecem seladas para todos até o moderador restaurar o acesso. Conteúdo de grupo não fica no celular; sem internet, só abrem as conversas 1:1. No 1:1 nada muda. Ver `docs/grupos.md` §11. | Decidido (25/11/2026) |
| D12 | Conversas ocultas e senha por conversa | Qualquer conversa (1:1 ou grupo) pode ser escondida com uma senha própria. Escondida, some da lista, do diretório, das bolhas e dos contadores. Tocar 7 vezes em "Conversas", no topo da lista, mostra as ocultas. Abrir uma delas pede a senha dela, **nunca a digital**. O conteúdo fica cifrado no celular com chave derivada dessa senha. Esqueceu a senha: só com "Esqueci a senha" do app (apaga tudo) e o moderador devolvendo o histórico pelo escrow. Fase F11, depois da G-C. Grupo oculto aparece nos 7 toques com o nome provisório: o nome cifrado só é buscado com a senha. Desenho e limites em `docs/ocultas.md`. | Decidido (25/11/2026) "Esconder conversa" só aparece com "Adicionar secrets" ligado no perfil (vem desligado). |

## 2. Suposições (corrigir se estiver errado)

- Uma organização por servidor. Todo usuário ativo aparece no diretório para iniciar conversa.
- Distribuição interna: Android por APK assinado ou teste interno da Play Store; iOS por TestFlight.
- Android mínimo 11 (API 30), exigido pelo chat flutuante (Bubbles).
- "A conexão expira conforme a geração do token": o token de convite tem prazo para ser usado
  (ex.: 24 h) e define o prazo de acesso do aparelho (ex.: 180 dias). Vencido, precisa de token novo.
- A senha do app é só local. O servidor nunca a recebe.
- Grupos ficam para depois, mas o banco e o protocolo já nascem prontos para N membros.

## 3. Pré-requisitos de máquina

Estado desta máquina em 24/11/2026: Docker instalado; Go, Flutter e cloudflared **não** instalados.

- Go 1.23 ou mais novo.
- Flutter (canal stable) com Android SDK e um emulador ou aparelho Android 11+.
- iOS: compilar exige macOS com Xcode e conta Apple Developer (US$ 99/ano). Sem Mac, usar
  macOS na nuvem (Codemagic ou GitHub Actions `macos-latest`).
- No servidor: Docker, pendrive para as chaves de escrow e do moderador, conta Cloudflare com o
  domínio e um tunnel criado.

## 4. Arquitetura

```
 App Flutter ──HTTPS/WSS──► Cloudflare (borda) ──tunnel──► cloudflared ──► directd (Go) ──► PostgreSQL
                                                                              ▲               (deploy/data/)
                                                         direct-admin (CLI) ──┘
```

- O Cloudflare termina o TLS. Ele vê metadados (quem conecta, quando, tamanho) e o token de
  acesso, mas nunca o conteúdo, que segue cifrado pelo E2E.
- `directd` não publica porta no host. Só o `cloudflared` alcança ele, pela rede interna do Docker.
- O Cloudflare fecha WebSocket ocioso em ~100 s. Cliente e servidor trocam ping a cada 30 s.

### 4.1 Estrutura do repositório

```
server/
  cmd/directd/         API HTTP + WebSocket
  cmd/direct-admin/    CLI do moderador
  internal/            auth, store (pgx), crypto, ws, migrations (goose)
app/                   projeto Flutter
deploy/                docker-compose.yml, config do cloudflared, scripts de backup
docs/                  PLANO.md, protocolo.md, ameacas.md, vetores/ (vetores de teste Go↔Dart)
```

### 4.2 Servidor (`directd`)

Bibliotecas: `net/http` da stdlib (rotas do Go 1.22+), `github.com/coder/websocket`, `pgx`,
`goose` para migrações, `golang.org/x/crypto`.

| Método | Rota | Função |
|--------|------|--------|
| POST | `/v1/enroll` | Token de convite + chaves públicas + dados do aparelho. Cria usuário/aparelho. |
| POST | `/v1/auth/challenge` | Devolve um nonce. |
| POST | `/v1/auth/verify` | Assinatura do nonce. Devolve token de acesso opaco de 15 min (salvo como hash). |
| GET | `/v1/directory` | Usuários ativos: nome, status, aparelhos e chaves públicas. |
| PUT | `/v1/me/profile` | Nome e status. |
| POST | `/v1/conversations` | Cria conversa 1:1 (grupo no futuro). |
| POST | `/v1/conversations/{id}/epochs` | Nova época com chaves embrulhadas para cada aparelho + escrow. |
| GET | `/v1/conversations/{id}/messages?after={seq}` | Histórico cifrado a partir de um número de sequência. |
| GET | `/v1/epochs/mine` | Chaves de época embrulhadas para este aparelho. |
| WS | `/v1/ws` | Envio e recebimento em tempo real. Token de acesso vai na primeira mensagem, não na URL. |

Regras: limite de tentativas por aparelho e por IP em `/v1/enroll` e `/v1/auth/*`; logs sem
conteúdo e sem tokens; aparelho revogado ou vencido recebe 401 e tem o WebSocket fechado.

### 4.3 Modelo de dados

```
users                (id, admin_label, display_name, status, created_at, disabled_at)
devices              (id, user_id, platform, model, os_version, app_version,
                      sign_pub, kex_pub, enrolled_at, last_seen_at, expires_at, revoked_at)
enrollment_tokens    (id, token_hash, user_id NULL=usuário novo, admin_label,
                      expires_at, device_ttl, used_at)
access_tokens        (token_hash, device_id, expires_at)
conversations        (id, kind 'direct'|'group', created_at)
conversation_members (conversation_id, user_id, joined_at, left_at)
epochs               (conversation_id, epoch, created_by_device, created_at)
epoch_key_wraps      (conversation_id, epoch, recipient_device_id NULL=escrow, wrapped_key)
messages             (conversation_id, seq, epoch, sender_device_id, nonce, ciphertext,
                      signature, created_at)
```

`last_seen_at`, `model` e `platform` respondem "quem perdeu o telefone" e "qual aparelho é qual".

## 5. Criptografia

Resumo. A especificação byte a byte sai na fase F1 (`docs/protocolo.md`).

### 5.1 Esquema

- **Por aparelho:** um par Ed25519 (assinar) e um par X25519 (receber chaves). Gerados no aparelho;
  a chave privada nunca sai dele.
- **Por conversa:** uma chave simétrica de 32 bytes por "época".
- **Mensagem:** XChaCha20-Poly1305 com a chave da época e nonce aleatório, assinada com o Ed25519
  do remetente.
- **Distribuição da chave da época:** sealed box (X25519) para cada aparelho ativo de cada membro
  e para a chave pública de escrow (se D5 = escrow).
- **Nova época** quando entra ou sai um aparelho ou membro. Quem envia a próxima mensagem detecta
  a mudança e cria a época. Aparelho revogado deixa de ler mensagens novas.
- **Bibliotecas:** app com `sodium_libs` (libsodium); servidor e CLI com `golang.org/x/crypto`
  (`nacl/box.SealAnonymous`/`OpenAnonymous`, compatíveis com `crypto_box_seal`). Vetores de teste
  em `docs/vetores/` garantem que Go e Dart produzem e abrem os mesmos bytes.
- **Fixação de chaves:** o QR do convite leva domínio, token e a impressão digital da chave de
  assinatura do servidor e da chave de escrow. O app recusa chaves que não batem.
- **Sem sigilo futuro (forward secrecy) por desenho.** Devolver histórico a aparelho novo exige
  chaves de longa duração. É o preço do requisito.

### 5.2 D5 — como devolver o histórico com E2E (decidido: opção A)

Escolha do usuário em 24/11/2026: **opção A, escrow organizacional offline.** A opção B fica
registrada abaixo só como alternativa descartada. Formatos em `docs/protocolo.md`.

**Opção A — escrow organizacional offline (escolhida).**
O moderador gera um par X25519 de escrow com `direct-admin escrow init`. A chave privada fica
cifrada com senha num pendrive ou máquina offline, fora do servidor. Toda chave de época também
é embrulhada para a chave pública de escrow. Ao vincular aparelho novo, o moderador roda
`direct-admin escrow rewrap`, que abre as chaves de época com a chave de escrow e as reembrulha
para o aparelho novo.
- Atende exatamente "agrego um aparelho novo e ele recebe as mensagens anteriores".
- Cloudflare e quem invadir o servidor não leem nada.
- Quem tiver a chave de escrow e a senha dela lê tudo. Guardar duas cópias offline.
- Durante o `rewrap` a chave privada passa pela memória do servidor. Alternativa: rodar o
  `rewrap` no notebook do moderador, falando com o banco por túnel SSH.

**Opção B — código de recuperação do usuário (descartada).**
No cadastro o app mostra 24 palavras. O servidor guarda as chaves do usuário cifradas com esse
código. Aparelho novo + código devolve o histórico.
- Nem o moderador lê.
- Usuário que perde o código perde o histórico. O moderador não consegue ajudar.

### 5.3 Chave do moderador

Ed25519 que assina os registros de grupo feitos pela CLI. Guarda igual à do escrow: arquivo cifrado
no pendrive (pode ser o mesmo, em arquivo separado e com outra senha), duas cópias. O servidor
recebe só a pública. Detalhes em `docs/protocolo-grupos.md` §3.

## 6. Fluxos

### 6.1 Cadastro (usuário novo)
1. Moderador: `direct-admin token create --new-user "João - Financeiro" --ttl 24h --device-ttl 180d`.
   A CLI imprime o token e um QR no terminal.
2. Usuário lê o QR no app (ou digita domínio e token).
3. App gera as chaves, chama `/v1/enroll` e recebe o `device_id`.
4. App pede a criação da senha local e depois nome e status.

### 6.2 Login do aparelho
1. App pede nonce em `/v1/auth/challenge`.
2. App assina com Ed25519 e envia a `/v1/auth/verify`.
3. Servidor confere assinatura, revogação e `expires_at`, e devolve token de acesso de 15 min.

### 6.3 Mensagens
- App aberto: WebSocket ativo; envio e recebimento em tempo real.
- App fechado: nada chega e nada avisa (D3). Ao abrir, o app sincroniza de `after=último seq`.
- Chat flutuante aberto: mantém WebSocket só daquela conversa (seção 9).

### 6.4 Aparelho perdido ou trocado
1. Moderador localiza o usuário: `direct-admin device list --user <id>` (modelo, último acesso).
2. `direct-admin device revoke <device_id>`. O servidor corta o acesso na hora.
3. `direct-admin token create --user <id> --ttl 24h`. Usuário cadastra o aparelho novo.
4. D5 = A: `direct-admin escrow rewrap --device <novo> --key /mnt/pendrive/escrow.key`.
   D5 = B: usuário digita o código de recuperação no aparelho novo.
5. App baixa o histórico cifrado e decifra localmente.

### 6.5 Esqueceu a senha do app
1. Na tela de bloqueio, "Esqueci a senha" explica as consequências e oferece
   "Apagar tudo neste aparelho" (necessário no iOS, que não tem "limpar dados" do app).
2. Com internet, o app envia antes a revogação pré-assinada do próprio aparelho
   (`docs/grupos.md` §11.3). O servidor revoga na hora, e nos grupos as mensagens da pessoa
   ficam seladas (D11). Sem internet, segue sem avisar; o moderador revoga pela CLI.
3. O app apaga banco local, chaves e Keychain/Keystore e volta ao cadastro.
4. O moderador reabre o mesmo token (`token reactivate`) ou cria outro (`token create --user`),
   e segue o fluxo 6.4 a partir do passo 4.

## 7. App Flutter

**Pacotes:** `sodium_libs` (cripto), `drift` + `sqlcipher_flutter_libs` (banco local cifrado),
`flutter_secure_storage` (Keychain/Keystore), `web_socket_channel`, `mobile_scanner` (QR).
Proteções de tela via código nativo próprio em `MainActivity.kt` e `AppDelegate.swift`, sem plugin.

**Telas:** cadastro (QR ou domínio + token) → criar senha → perfil (nome, status) → conversas →
diretório → chat 1:1 → ajustes (perfil, apagar tudo). Tela de bloqueio na frente de tudo.

**Trava por senha:**
- Argon2id (libsodium `crypto_pwhash`) gera a chave que abre a chave-mestra local. A chave-mestra
  abre o banco SQLCipher e as chaves privadas.
- Bloqueia ao abrir o app e ao voltar do segundo plano.
- Atraso crescente após senhas erradas.
- No iOS o Keychain sobrevive à desinstalação. No primeiro início (sem marca em `UserDefaults`)
  o app apaga o Keychain para não reaproveitar chaves antigas.

**Digital (D9):**
- Opcional. Ativada em Ajustes, depois de digitar a senha.
- A chave-mestra também fica embrulhada por uma chave do Keystore/Keychain que só abre com
  biometria. O vínculo é criptográfico, não só o "sim/não" do sensor (que app adulterado em
  aparelho com root contorna). Sugestão: `biometric_storage` em vez de `local_auth` puro.
- Cadastrar digital nova no aparelho invalida essa chave. O app volta a pedir a senha.
- A senha continua como reserva e sempre abre tudo.
- Serve para entrar no app e para reabrir conversa trancada (seção 9).

## 8. Proteções de tela

| Proteção | Android | iOS |
|----------|---------|-----|
| Bloquear print e gravação | `FLAG_SECURE` em todas as janelas, inclusive no chat flutuante. Print sai preto. | **Não existe API para bloquear.** Mitigação: esconder o conteúdo quando `UIScreen.isCaptured` (gravação/espelhamento) e avisar ao detectar `userDidTakeScreenshotNotification` (o print já foi tirado). |
| Miniatura no seletor de apps | Coberta pelo `FLAG_SECURE`. | Cobrir a tela ao entrar em segundo plano. |
| Sobreposição de outros apps | `setHideOverlayWindows(true)` (Android 12+, permissão `HIDE_OVERLAY_WINDOWS`) esconde sobreposições alheias com o app aberto. `filterTouchesWhenObscured` na `FlutterView` ignora toques sob sobreposição (contra tapjacking, Android 11). | O sistema não permite sobreposição de outros apps. Nada a fazer. |

Existe um truque não documentado no iOS (renderizar o conteúdo dentro da camada de um campo de
senha) que faz o print sair em branco. Funciona hoje, mas a Apple pode quebrar em qualquer versão.
Fica fora do MVP; avaliar na F6 se for essencial.

## 9. Chat flutuante (estilo Messenger)

**Android (11+), API de Bubbles:**
- Botão "Abrir em pop-up" no topo do chat 1:1.
- O app publica uma notificação de conversa com `BubbleMetadata` (atalho de conversa, `Person`,
  `MessagingStyle`), expandida e sem alerta. Não depende de push: o próprio app cria a bolha.
- A bolha abre `MiniChatActivity` (`allowEmbedded`, `resizeableActivity`) com um segundo
  `FlutterEngine` apontando para `miniChatMain(conversationId)`. `FLAG_SECURE` aplicado.
- Enquanto a bolha existir, um foreground service do tipo `remoteMessaging` (Android 14+) mantém
  o WebSocket daquela conversa. Fechou a bolha, o serviço para.
- Arrastar a bolha para o lixo ou fechá-la dispara o `deleteIntent` do `BubbleMetadata`. O
  serviço para e **aquela conversa fica trancada** (D7). Reabrir a conversa, no app ou em
  pop-up, pede senha ou digital. O resto do app segue aberto.
- Se o app estiver bloqueado, a bolha mostra a tela de senha.
- O usuário precisa permitir bolhas para o app. Alguns fabricantes desativam por padrão; o app
  mostra como ativar.

**iOS:** a Apple não permite janela flutuante sobre outros apps. A alternativa é um mini-chat
flutuante **dentro** do app, por cima das outras telas dele. Com o app em segundo plano a conexão
cai em segundos e nada chega (D3). Fechar o mini-chat tranca a conversa do mesmo jeito (D7).

### 9.1 Decisões da F7

- **Dois engines, um dono das chaves.** O engine principal (isolate `main`) fica em
  `FlutterEngineCache` e detém chave-mestra, banco SQLCipher e WebSocket; sobrevive à
  `MainActivity` enquanto o processo viver. A bolha é outro engine, só de tela (`miniChatMain`),
  que fala com o principal por `IsolateNameServer`/`SendPort`, em memória (`app/lib/bubble/`).
  Não há segundo banco nem segundo WebSocket. Extras de `Intent` e disco só levam o id da
  conversa; notificação e atalho levam também o nome do contato, sem conteúdo de mensagem.
  A senha digitada na bolha, e a chave lida pela digital dela, passam por essa ponte.
- **Segundo plano com bolha.** A interface principal tranca (volta pedindo senha ou digital), mas
  a sessão continua aberta, com o WebSocket no escopo só das conversas das bolhas. A chave-mestra
  fica em memória enquanto houver bolha. O botão "Bloquear" (ou o processo morrer) fecha tudo, e a
  bolha mostra a trava.
- **Tranca automática da bolha** (revisão de segurança, B1). Ao desligar a tela, e após 5 minutos
  sem interação com a interface principal trancada (`bubbleIdleTimeout`), a conversa de toda bolha é
  trancada (D7) e a chave-mestra sai da memória. Voltar pede a trava do app e depois a da conversa.
- **Tranca (D7).** Gravada em `chat_meta` (`locked:<id>`) no banco cifrado. Se a bolha é removida
  com o banco fechado, o id fica pendente em `SharedPreferences` e é gravado ao abrir. Só sai com
  reautenticação feita naquela conversa.
- A bolha mostra as últimas 60 mensagens e miniaturas; anexar, ampliar e salvar foto só no app.
- `MainActivity` renderiza em `TextureView`: com `SurfaceView`, o Impeller/OpenGLES caía no
  emulador com dois engines. Falta conferir em aparelho real.

## 10. CLI do moderador (`direct-admin`)

```
direct-admin token create --new-user "<rótulo>" --ttl 24h [--device-ttl 180d]
direct-admin token create --user <id> --ttl 24h          # aparelho novo para usuário existente
direct-admin token list
direct-admin token revoke <id>
direct-admin token reactivate <id> --ttl 24h             # reabre o mesmo token para recadastro (D11); o QR não é reimpresso
direct-admin user list
direct-admin user show <id>
direct-admin user disable <id>
direct-admin device list [--user <id>]
direct-admin device revoke <id>
direct-admin escrow init --out /mnt/pendrive/escrow.key  # só se D5 = A
direct-admin escrow rewrap --device <id> --key /mnt/pendrive/escrow.key
direct-admin moderator init --out /mnt/pendrive/moderador.key    # offline
direct-admin moderator register --pub <b64u>             # no servidor, só a pública
direct-admin moderator qr                                # QR de fixação da chave do moderador
direct-admin group list
direct-admin group show <id>
direct-admin group create --label "<rótulo>" --admin <user_id>... [--member <user_id>...] --mod-key <arquivo>
direct-admin group remove-member <id> <user_id> --mod-key <arquivo>
direct-admin group close <id> --mod-key <arquivo>
direct-admin media saves [--user <id>]                   # quem salvou foto na galeria, quando
direct-admin media lookup <save_id>                      # save_id lido do EXIF de foto vazada
direct-admin media prune [--older 30d]                   # apaga anexos enviados e nunca usados
```

Roda no servidor, direto no banco. O token aparece em texto e em QR no terminal.

## 11. Implantação

- `deploy/docker-compose.yml`: `postgres`, `directd`, `cloudflared`
  (token do tunnel via arquivo de segredo, não variável no compose versionado).
- **Dados na pasta do projeto (D6):** banco em `deploy/data/postgres/` e dados do `directd`
  (chave de assinatura do servidor) em `deploy/data/directd/`, por bind mount. Parar ou apagar os
  contêineres não perde nada. `deploy/data/` e `deploy/secrets/` ficam fora do git.
- **Instalador:** `docker compose run --rm setup` roda `deploy/setup.sh` dentro do compose
  (passo a passo em `deploy/README.md`). O contêiner não tem rede e sobe um PostgreSQL e um
  `directd` temporários, só em socket local. Por isso exige os serviços parados.
  - Gera a senha do banco.
  - Pede e grava o token do tunnel.
  - Define `DIRECT_PUBLIC_HOST`.
  - Cria as pastas com permissão restrita.
  - Gera as chaves privadas de escrow e do moderador **no pendrive** (`DIRECT_PENDRIVE=<caminho>`),
    protegidas por senha. Grava no servidor só as públicas (a do moderador em
    `deploy/data/moderador.pub`; registrar com `moderator register`) e recusa gravar privada dentro do
    projeto.
  - Marca o registro de comandos como só de acréscimo (`chattr +a`).
  - No fim, oferece criar o primeiro convite.
- No painel da Cloudflare: hostname público do tunnel apontando para `http://directd:8080`;
  regra de limite de requisições em `/v1/enroll` e `/v1/auth/*`.
- `directd` só aceita `CF-Connecting-IP` de conexão vinda do `cloudflared`
  (`DIRECT_TRUSTED_PROXY`).
- Sem backup periódico (decisão de 25/11/2026). A cópia é a própria pasta `deploy/data/`.
- Segredos (senha do banco, token do tunnel, chave de assinatura do servidor) fora do repositório.

## 12. Fases, subsessões e força do modelo

Cada fase é uma subsessão **nova** (contexto `fresh`), com brief curto que aponta para este
arquivo e para `docs/protocolo.md`. Não usar fork: fork carrega a conversa inteira e gasta cota.

| Fase | Entrega | Depende de | Modelo | Esforço | Pronto quando |
|------|---------|------------|--------|---------|---------------|
| F0 Fundação | Pastas, `go mod init`, `flutter create`, compose com Postgres e cloudflared, Makefile, CI de lint/teste | — | Haiku 5.5 | low | `make test` roda nos dois lados; `docker compose up postgres` sobe |
| F1 Protocolo e ameaças | `docs/protocolo.md`, `docs/ameacas.md`, `docs/vetores/*.json` | D5 decidida | Opus 5.5 | high | Fluxos da seção 6 descritos byte a byte; vetores gerados |
| F2 Servidor | `directd`: cadastro, auth, diretório, conversas, épocas, mensagens, WebSocket | F0, F1 | Sonnet 5.5 | medium | `go test ./...` e teste de integração cadastro→auth→enviar→buscar contra Postgres real |
| F3 CLI admin | `direct-admin`: tokens com QR, usuários, aparelhos, revogação, escrow, consulta de fotos salvas | F2, F5b | Sonnet 5.5 | high | Teste: aparelho novo lê histórico após `rewrap`; aparelho revogado recebe 401 |
| F4 App base | Cadastro por QR, chaves, senha e bloqueio, SQLCipher, perfil, "apagar tudo" | F0, F1 | Sonnet 5.5 | medium | Testes da trava passam; app cadastra no emulador contra o `directd` |
| F5 Chat 1:1 | Diretório, conversas, chat, WebSocket, cifra E2E, sincronização de histórico | F2, F4 | Sonnet 5.5 | high | Dois emuladores conversam; vetores da F1 passam em Dart |
| F5b Imagens | Seção 15: anexo no protocolo, blobs e registro de salvamento no `directd`, enviar/receber/salvar no app | F5 | Sonnet 5.5 | high | Foto vai e volta entre dois aparelhos; foto salva tem EXIF com `save_id` registrado no banco |
| F6 Digital e proteções nativas | Digital (seção 7) e seção 8 | F4 | Sonnet 5.5 | medium | Digital abre o app; digital nova cadastrada força a senha; print sai preto no Android |
| F7 Chat flutuante | Seção 9, incluindo trancar a conversa ao fechar a bolha (D7) | F5, F5b, F6 | Sonnet 5.5 | high | Bolha conversa com o app em segundo plano num Android 11+ real; jogar no lixo tranca a conversa |
| F8 Revisão de segurança | Revisão de cripto e auth contra a spec (`/security-review` ou `/code-review high`); correções | F3, F5b, F6, F7 | Opus 5.5 | high | Achados críticos e altos corrigidos |
| F9 Build e distribuição | Assinatura Android, pipeline iOS em macOS na nuvem, deploy no servidor | F7, F8 | Haiku 5.5 | low | APK assinado instalado; build no TestFlight; tunnel no ar |

**Paralelismo possível** (arquivos diferentes): F0 com F1; F2 com F4; F3 com F5; F5b com F6
(só edições aditivas em `pubspec.yaml`, `Info.plist` e `AndroidManifest.xml`, relendo antes de editar).

### 12.1 Orçamento de uso

Leitura em 24/11/2026 (plano Pro): semanal de todos os modelos em 47%, semanal do Fable em 83%,
renovação em 29/11 às 04:00 (Brasília).

- **Até 29/11:** F0 e F1. Depois F2 e F4, só se o semanal estiver abaixo de ~75% ao fim da F1.
- **Após 29/11:** F3, F5, F6, F7, F8, F9.
- Não usar Fable (cota própria quase no fim). Nunca `xhigh`, `max` ou `/code-review ultra`.
- Opus só onde erro custa caro e a saída é curta (F1 spec, F8 revisão). Código em Sonnet.
- Uma sessão pesada por vez quando a janela de 5 h passar de 70%.
- Cada sessão já começa com ~55k tokens de ferramentas, skills e MCP. Desativar neste projeto os
  plugins sem uso (stripe, sanity, honeycomb, remotion, forge, hostinger, offensive, gsd) reduz o
  custo de toda mensagem. Fazer pelo `claude` no terminal (`/plugin`) ou em `enabledPlugins` no
  `.claude/settings.json` do projeto.
- Encerrar a subsessão ao fim da fase. Fase nova, sessão nova.

## 13. Fora do MVP

Interface de grupos (proposta em `docs/grupos.md`), vídeo e outros anexos além de imagem,
chamadas, notificações push, detecção de root/jailbreak, várias organizações por servidor,
painel web.

## 14. Riscos

- **iOS:** sem chat flutuante fora do app, sem bloqueio real de print, sem receber em segundo plano.
- **iOS:** build exige macOS e conta Apple Developer; TestFlight expira builds em 90 dias.
- **Escrow (D5 = A):** perder a chave = ninguém recupera histórico; vazar a chave + senha = todo
  histórico legível.
- **Bolhas:** usuário ou fabricante pode desativar; o chat flutuante some nesses aparelhos.
- **Play Store:** foreground service `remoteMessaging` precisa de declaração e justificativa.
- **Sem push:** usuário só sabe de mensagem nova abrindo o app. Combinado (D3), mas vale avisar
  a organização.
- **EXIF de rastreio:** some quando a foto passa por WhatsApp, Instagram, editor ou foto da tela
  tirada com outro aparelho. Rastreia o arquivo original, não cópias. Ver D10.

## 15. Imagens (D8)

- **Enviar:** câmera ou galeria (`image_picker`). Antes de enviar, o app reduz para no máximo
  2048 px, recomprime em JPEG e **remove todo o EXIF original** (GPS, modelo do aparelho).
- **Cifra:** chave aleatória de 32 bytes por imagem, XChaCha20-Poly1305. O servidor recebe só o
  blob cifrado (`POST /v1/blobs`, preso a uma conversa, limite 10 MB) e só o entrega a membros
  dela (`GET /v1/blobs/{id}`).
- **Mensagem:** a mensagem E2E leva `blob_id`, chave, SHA-256 do blob, tipo, dimensões e uma
  miniatura pequena. Como a chave da imagem vai dentro da mensagem, escrow e recuperação de
  histórico cobrem imagens sem mudança.
- **No aparelho:** a imagem fica só cifrada (banco SQLCipher ou arquivo cifrado com a
  chave-mestra). Nunca em cache de disco em claro; exibição a partir da memória.
- **Salvar na galeria:**
  1. Botão "Salvar". O app pede ao servidor um `save_id` (`POST /v1/media/saves` com conversa e
     `seq`). Sem conexão, não salva.
  2. O servidor grava `media_saves(save_id, conversation_id, seq, user_id, device_id, saved_at)`.
     Ele fica sabendo que aquela mensagem foi salva, nunca o conteúdo.
  3. O app aplica a marca d'água visível (D10) só na cópia salva: texto `<rótulo> · <data UTC> ·
     <save_id curto>` repetido em diagonal pela foto inteira, semitransparente, com tamanho
     proporcional à imagem, para que cortar não remova. A visualização dentro do app fica sem marca.
  4. O app grava a foto com EXIF de identificação: `Artist` = rótulo do usuário;
     `ImageDescription` e `UserComment` = `Direct save_id=<id> user=<id> device=<id> at=<UTC>`.
  5. Moderador consulta com `direct-admin media saves` e `direct-admin media lookup` (seção 10).

## 16. Grupos

Especificação em `docs/protocolo-grupos.md`.

Proposta em `docs/grupos.md`, com G1 a G4 decididos em 25/11/2026. Mensagens seladas de quem
perdeu o acesso (D11): `docs/grupos.md` §11.
