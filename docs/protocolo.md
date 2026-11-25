# Protocolo Direct v1

Especificação byte a byte do protocolo entre app (Flutter + `sodium_libs`), servidor (`directd`)
e CLI (`direct-admin`). Complementa `docs/PLANO.md` (seções 5 e 6). Modelo de ameaças em
`docs/ameacas.md`. Vetores de teste em `docs/vetores/`.

**Regra de ouro:** se o código diverge deste documento, o código está errado. Mudar o protocolo
exige mudar este documento, o gerador de vetores e os vetores no mesmo commit.

"Deve" = obrigatório. "Recomendado" = pode ser ajustado pela fase que implementa, sem afetar
compatibilidade.

---

## 1. Primitivas

| Uso | Primitiva | libsodium (`sodium_libs` usa por baixo) | Go (`golang.org/x/crypto` e stdlib) |
|-----|-----------|-------------------------------------------|-------------------------------------|
| Assinatura | Ed25519 (RFC 8032) | `crypto_sign_seed_keypair`, `crypto_sign_detached`, `crypto_sign_verify_detached` | `ed25519.NewKeyFromSeed`, `ed25519.Sign`, `ed25519.Verify` |
| Troca de chave | X25519 | `crypto_scalarmult_base`, `crypto_scalarmult` | `curve25519.X25519` |
| Embrulho de chave | Sealed box (X25519 + XSalsa20-Poly1305) | `crypto_box_seal`, `crypto_box_seal_open` | `box.SealAnonymous`, `box.OpenAnonymous` (`nacl/box`) |
| Cifra de mensagem | XChaCha20-Poly1305 IETF | `crypto_aead_xchacha20poly1305_ietf_encrypt/decrypt` | `chacha20poly1305.NewX` |
| Hash | BLAKE2b sem chave, sem salt, sem personalização | `crypto_generichash` (saída 32 bytes) | `blake2b.Sum256` |
| Preenchimento | ISO/IEC 7816-4, bloco 256 | `sodium_pad`, `sodium_unpad` | implementação própria (12 linhas, ver gerador) |
| Senha do escrow | Argon2id v1.3 | `crypto_pwhash` com `crypto_pwhash_ALG_ARGON2ID13` | `argon2.IDKey` |
| Hash de segredo no servidor | SHA-256 | — (só servidor) | `crypto/sha256` |
| Aleatoriedade | CSPRNG do sistema | `randombytes_buf` | `crypto/rand` |

Tamanhos fixos: semente Ed25519 32, chave pública Ed25519 32, assinatura 64, chave X25519 32
(privada e pública), sealed box = 48 + tamanho do texto claro, nonce XChaCha 24, tag 16.

Chave privada Ed25519 em libsodium e em Go tem 64 bytes (`semente || pública`). O que se guarda é
a semente de 32 bytes.

Ed25519: libsodium recusa algumas chaves e assinaturas malformadas (ponto de ordem baixa) que o
Go aceita. Só um aparelho malicioso produz isso, e o efeito é o app descartar as mensagens dele.
Não há o que alinhar.

Nota de versão: `golang.org/x/crypto` v0.56.0 em diante exige Go 1.26. Os vetores foram gerados com
Go 1.25 e `x/crypto` v0.55.0 (`docs/vetores/gerador/go.mod`). Os bytes não dependem da versão.

## 2. Codificação

### 2.1 Bytes dentro de estruturas assinadas, AAD e hashes

- **Rótulo de domínio:** toda estrutura começa com um rótulo ASCII seguido de um byte `0x00`.
  Exemplo: `direct/v1/msg` vira os 14 bytes `6469726563742f76312f6d736700`. Os rótulos são
  distintos e terminam em `0x00`, então nenhum é prefixo de outro.
- **Inteiros:** sem sinal, big-endian, largura fixa: `u32` (4 bytes) ou `u64` (8 bytes).
- **UUID:** 16 bytes, na ordem em que os dígitos hexadecimais aparecem no texto (RFC 9562).
- **Campo variável:** `u32(tamanho) || bytes`. Texto é UTF-8 sem normalização.
- **Concatenação:** `||`. Nenhum separador além do que está escrito.

Tabela de rótulos (todos com `0x00` no fim):

| Rótulo | Uso | Seção |
|--------|-----|-------|
| `direct/v1/server-code` | código de verificação do servidor | 4.3 |
| `direct/v1/device-code` | código do aparelho, conferido antes do `rewrap` (hash) | 13.4 |
| `direct/v1/enroll` | cadastro (assinado pelo convite e pelo aparelho) | 5.2 |
| `direct/v1/device-cert` | certificado de aparelho (assinado pelo servidor) | 5.3 |
| `direct/v1/auth` | login (assinado pelo aparelho) | 6.2 |
| `direct/v1/revoked` | prova de revogação (assinada pelo servidor) | 6.4 |
| `direct/v1/epoch-key` | compromisso da chave de época (hash) | 9.2 |
| `direct/v1/epoch` | declaração de época (assinada pelo criador) | 9.3 |
| `direct/v1/msg` | AAD da mensagem | 10.3 |
| `direct/v1/msg-sig` | assinatura da mensagem | 10.4 |
| `direct/v1/blob` | AAD do blob de anexo | 18.2 |

Grupos acrescentam 8 rótulos, definidos em `protocolo-grupos.md` §1: `direct/v1/group-change`,
`direct/v1/group-link`, `direct/v1/group-epoch`, `direct/v1/group-meta-commit`,
`direct/v1/group-meta`, `direct/v1/sealed`, `direct/v1/self-revoke` e `direct/v1/server-code-m`.

### 2.2 JSON (HTTP e WebSocket)

- UTF-8, `Content-Type: application/json`. Corpo de requisição HTTP até 64 KiB (256 KiB nas
  rotas de época e de grupo, `protocolo-grupos.md` §1).
- **Binário:** base64url (RFC 4648 §5) **sem** `=`. Quem decodifica deve recusar `=`, caracteres
  fora do alfabeto e codificação não canônica: decodificar, codificar de novo e comparar com a
  string recebida. Em Dart, `base64Url.encode` põe `=`: remover. Para decodificar, usar
  `base64Url.decode(base64Url.normalize(s))` e depois a comparação canônica. Em Go,
  `base64.RawURLEncoding.Strict()`.
- **Tamanho exato:** todo campo binário tem tamanho fixo ou máximo nesta spec. Tamanho errado = 400.
- **UUID:** texto minúsculo `8-4-4-4-12` (36 caracteres). Maiúscula = 400. A versão do UUID não é
  conferida. O servidor gera UUIDv4 para usuário, aparelho, conversa direta e convite; o app gera
  UUIDv4 para `message_id`. O `conversation_id` de grupo é gerado por quem cria (app ou CLI), porque
  entra no registro assinado.
- **Tempo:** milissegundos Unix (`u64`) como número JSON. Todos os valores cabem em 2^53.
- **Campos desconhecidos:** ignorados por quem recebe (permite evoluir sem quebrar).
- **Erro HTTP:** `{"error": {"code": "<código>", "message": "<texto livre>"}}`. Códigos na seção 14.

### 2.3 Limites de texto

| Campo | Limite |
|-------|--------|
| `admin_label` | 1 a 100 bytes UTF-8, sem caracteres de controle |
| `display_name` | 1 a 64 code points, sem caracteres de controle |
| `status` | 0 a 140 code points, sem caracteres de controle |
| `platform` | `android` ou `ios` |
| `model`, `os_version`, `app_version` | até 64 bytes UTF-8 |

## 3. Chaves e identidades

| Chave | Tipo | Onde nasce | Onde fica a parte privada | Quem confia na pública |
|-------|------|------------|---------------------------|------------------------|
| Assinatura do servidor `server_sign` | Ed25519 | `directd` na primeira subida (ou CLI) | arquivo de segredo no servidor (32 bytes da semente, modo 0600, fora do repositório) | app, fixada pelo QR |
| Escrow `escrow` | X25519 | `direct-admin escrow init` | arquivo cifrado com senha, offline (seção 13) | app, fixada pelo QR |
| Convite `invite` | Ed25519 | `direct-admin token create` | só no QR (o servidor guarda a pública) | servidor |
| Assinatura do aparelho `sign` | Ed25519 | app, no cadastro | aparelho, protegida pela trava local | servidor e outros apps, via certificado |
| Recebimento do aparelho `kex` | X25519 | app, no cadastro | aparelho, protegida pela trava local | quem embrulha chaves de época |
| Chave de época `K` | 32 bytes simétricos | app que cria a época | aparelhos destinatários e escrow (embrulhada) | — |
| Moderador `mod_sign` | Ed25519 | `direct-admin moderator init`, offline | arquivo cifrado com senha, offline (`protocolo-grupos.md` §3) | app, fixada pelo QR v=2 ou de fixação |

O servidor guarda `server_sign_pub`, `escrow_pub` e `mod_pub` numa tabela de configuração
(`server_keys`).
`escrow_pub` não muda na v1: trocar exige novo QR para todos os aparelhos.

**Aparelho ativo:** `revoked_at IS NULL`, `expires_at > agora` e o usuário dono com
`disabled_at IS NULL`. Só aparelho ativo autentica, aparece no diretório e entra em época nova.

**Membro ativo** (grupos): usuário não desativado e com ao menos um aparelho ativo. Nos grupos, a
mensagem de autor inativo vai selada (`protocolo-grupos.md` §7).

## 4. Convite (QR)

### 4.1 Geração

`direct-admin token create` gera 32 bytes aleatórios `invite_seed`, deriva o par Ed25519
(`invite_pub` = pública de `crypto_sign_seed_keypair(invite_seed)`) e grava em
`enrollment_tokens` só `invite_pub` (no lugar de `token_hash` do PLANO 4.3), o usuário alvo,
`expires_at` e `device_ttl`. A semente nunca é gravada. A CLI recusa prazo de convite acima de
7 dias.

Motivo: o Cloudflare termina o TLS e vê tudo o que o app envia. Se o app mandasse o token em
claro, o Cloudflare poderia descartar a requisição e cadastrar um aparelho dele no lugar. Com a
semente, o app só envia assinaturas sobre as próprias chaves (seção 5).

### 4.2 Conteúdo do QR

Texto do QR (modo byte, UTF-8, correção de erro M):

```
direct://enroll?v=1&h=<host>&t=<invite_seed>&s=<server_sign_pub>&e=<escrow_pub>
```

| Parâmetro | Conteúdo |
|-----------|----------|
| `v` | `1` |
| `h` | hostname público (o do Cloudflare Tunnel). Só `a-z`, `0-9`, `-`, `.`; 1 a 253 caracteres; sem porta, sem ponto final, sem maiúscula |
| `t` | `invite_seed`, base64url de 32 bytes (43 caracteres) |
| `s` | `server_sign_pub`, base64url de 32 bytes |
| `e` | `escrow_pub`, base64url de 32 bytes |

O PLANO fala em "impressão digital" das chaves. O QR leva as chaves públicas inteiras: têm o
mesmo tamanho de um hash de 32 bytes e dispensam buscar as chaves por um canal que o Cloudflare
controla.

O app deve recusar o QR se: esquema diferente de `direct`, autoridade diferente de `enroll`,
`v` diferente de `1`, parâmetro faltando, repetido ou desconhecido, `%` em qualquer lugar,
base64url inválido ou tamanho errado, hostname fora da regra. A CLI escreve os parâmetros na ordem
acima; o app aceita qualquer ordem. Exemplos válidos e inválidos em `vetores/convite.json`.

Com a chave do moderador registrada, a CLI escreve o QR `v=2`, com o parâmetro `m`
(`protocolo-grupos.md` §3.2). Aparelhos já cadastrados a fixam pelo QR `direct://pin` ou por código
(§3.4).

URLs derivadas: `https://<h>/v1/...` e `wss://<h>/v1/ws`. TLS validado pelo sistema, sem fixar
certificado (o Cloudflare troca certificados). A segurança vem das chaves fixadas, não do TLS.

### 4.3 Código de verificação (entrada manual)

A CLI imprime, junto com o QR, o código de verificação do servidor:

```
dg = BLAKE2b-256( "direct/v1/server-code\0" || server_sign_pub || escrow_pub )      # 86 bytes de entrada
para i em 0..3:  grupo_i = u40_big_endian(dg[5i .. 5i+5]) mod 100000, com 5 dígitos (zeros à esquerda)
código = grupo_0 " " grupo_1 " " grupo_2 " " grupo_3                                # 20 dígitos
```

Entrada manual no app: o usuário digita host, token (os 43 caracteres de `t`) e o código. O app
chama `GET /v1/server-info`, calcula o código com as chaves recebidas, ignora espaços no que foi
digitado e compara. Diferente = aborta com aviso de servidor não confiável. Igual = fixa as chaves
recebidas e segue como se tivesse lido o QR.

`GET /v1/server-info` (rota nova, sem autenticação) →
`{"server_sign_pub": b64u, "escrow_pub": b64u, "mod_pub": b64u | null}`. Num convite `v=2` o código
cobre as três chaves (`protocolo-grupos.md` §3.3).

O código é o mesmo para todos os convites do servidor. A CLI pode imprimi-lo uma vez em papel.

## 5. Cadastro — `POST /v1/enroll` (fluxo 6.1 e passo 3 do 6.4)

### 5.1 Requisição

O app gera `sign` (semente de 32 bytes aleatórios) e `kex` (32 bytes aleatórios) e envia:

```json
{
  "invite_pub": "<b64u 32>",
  "sign_pub": "<b64u 32>",
  "kex_pub": "<b64u 32>",
  "platform": "android",
  "model": "Pixel 8",
  "os_version": "15",
  "app_version": "1.0.0",
  "invite_sig": "<b64u 64>",
  "proof": "<b64u 64>"
}
```

### 5.2 Bytes assinados

```
enroll_bytes = "direct/v1/enroll\0" || invite_pub(32) || sign_pub(32) || kex_pub(32)      # 113 bytes
invite_sig   = Ed25519_sign(invite_seed, enroll_bytes)    # prova que tem o convite
proof        = Ed25519_sign(sign_seed,   enroll_bytes)    # prova de posse da chave do aparelho
```

### 5.3 Certificado de aparelho

```
cert_bytes = "direct/v1/device-cert\0"
          || device_id(16) || user_id(16) || sign_pub(32) || kex_pub(32)
          || u64(enrolled_at) || u64(expires_at)
          || u32(len(admin_label)) || admin_label(UTF-8)                                # 138 + len bytes
cert_sig   = Ed25519_sign(server_sign_seed, cert_bytes)
```

Forma JSON (`DeviceCert`), usada no cadastro, no diretório e em `/v1/devices`:

```json
{
  "device_id": "uuid", "user_id": "uuid", "admin_label": "João - Financeiro",
  "sign_pub": "<b64u 32>", "kex_pub": "<b64u 32>",
  "enrolled_at": 1795003600000, "expires_at": 1810555600000,
  "sig": "<b64u 64>"
}
```

`admin_label` é o rótulo que o moderador deu ao usuário. Entra no certificado para que ninguém no
caminho troque o nome exibido de um usuário pelo de outro.

### 5.4 O servidor, na ordem

1. Valida formato e tamanhos. Erro: 400 `bad_request`.
2. Busca `enrollment_tokens` por `invite_pub`. Verifica `invite_sig` e `proof` sobre
   `enroll_bytes`. Recusa `kex_pub` de ordem baixa: `curve25519.X25519(qualquer_escalar, kex_pub)`
   retorna erro (lista de pontos em `vetores/cadastro.json`). Qualquer falha aqui, convite
   inexistente, vencido ou já usado: 401 `invite_invalid`, sempre a mesma resposta.
   - Exceção idempotente: se o convite já foi usado **pelo mesmo `sign_pub`**, devolve 200 com o
     mesmo aparelho (o Cloudflare ou a rede podem repetir a requisição).
3. Recusa `sign_pub` já cadastrado em outro aparelho: 409 `key_in_use`. Usuário existente com 4
   aparelhos ativos: 409 `device_limit`, sem gastar o convite.
4. Numa transação: marca `used_at` com
   `UPDATE ... WHERE invite_pub=$1 AND used_at IS NULL AND expires_at > now()`; cria o usuário (convite
   `--new-user`, com `admin_label` do convite) ou usa o existente (`--user`); cria o aparelho com
   `enrolled_at = agora`, `expires_at = agora + device_ttl`; calcula e guarda `cert_sig`.
5. Responde 200:

```json
{ "new_user": true, "cert": { ...DeviceCert... } }
```

### 5.5 O app, ao receber

1. Confere que `cert.sign_pub` e `cert.kex_pub` são os que enviou.
2. Monta `cert_bytes` e verifica `cert.sig` com `server_sign_pub` fixada. Falha = aborta e apaga
   as chaves geradas (servidor falso ou adulteração no caminho).
3. Guarda `host`, `server_sign_pub`, `escrow_pub`, `mod_sign_pub` (QR `v=2`), `device_id`,
   `user_id`, as chaves e o certificado. Descarta `invite_seed`. Gera a revogação pré-assinada
   (`protocolo-grupos.md` §8.2).
4. `new_user = true`: segue para criar senha e perfil (`PUT /v1/me/profile`). Senão, só senha.

## 6. Login (fluxo 6.2)

### 6.1 `POST /v1/auth/challenge`

Requisição `{"device_id": "uuid"}`. Resposta `{"challenge": "<b64u 32>", "expires_at": ms}`.

O servidor gera 32 bytes aleatórios, guarda `(device_id, challenge, expires_at = agora + 60 s)`
(tabela nova `auth_challenges`) e responde. Para `device_id` inexistente responde igual, com um
desafio que não grava (não revela quem existe).

### 6.2 `POST /v1/auth/verify`

```
auth_bytes = "direct/v1/auth\0" || server_sign_pub(32) || device_id(16) || challenge(32)    # 95 bytes
sig        = Ed25519_sign(sign_seed, auth_bytes)
```

Requisição `{"device_id": "uuid", "challenge": "<b64u 32>", "sig": "<b64u 64>"}`.

`server_sign_pub` no assinado prende a assinatura a este servidor.

O servidor, na ordem:
1. Busca e **apaga** o desafio (uso único, com sucesso ou falha). Inexistente ou vencido: 401
   `auth_failed`.
2. Verifica `sig` com o `sign_pub` do aparelho. Falha: 401 `auth_failed`.
3. Aparelho revogado ou usuário desativado: 401 `device_revoked` com prova (6.4). Aparelho
   vencido: 401 `device_expired`. Só depois da assinatura válida, para não revelar estado a quem
   não tem a chave.
4. Gera `access_token` = 32 bytes aleatórios, guarda `SHA-256(access_token)` em `access_tokens`
   com `expires_at = agora + 15 min`. Máximo 5 tokens válidos por aparelho (app principal e chat
   flutuante podem ter o seu); ao passar, apaga o mais antigo.
5. Responde `{"access_token": "<b64u 32>", "expires_at": ms, "server_time": ms}`.

### 6.3 Uso do token

HTTP: `Authorization: Bearer <access_token em base64url>`. WebSocket: no quadro `auth` (seção 11).
O servidor busca por `SHA-256(token)`, confere `expires_at`, e confere que o aparelho segue ativo
**em toda requisição**. Token inválido ou vencido: 401 `unauthorized`. Aparelho revogado ou
vencido: 401 `device_revoked` (sem prova; o app faz login para obter a prova) ou `device_expired`.

O app renova o token fazendo login de novo (6.1 e 6.2) um minuto antes de vencer ou ao receber 401
`unauthorized`.

### 6.4 Prova de revogação

O app apaga tudo ao saber que foi revogado (seção 12). Para que o Cloudflare não consiga forçar
isso com uma resposta falsa, a resposta de revogação no `verify` vem assinada:

```
revoked_bytes = "direct/v1/revoked\0" || device_id(16) || challenge(32)       # 66 bytes
revoked_sig   = Ed25519_sign(server_sign_seed, revoked_bytes)
```

Resposta: `{"error": {"code": "device_revoked", "message": "..."}, "revoked_sig": "<b64u 64>"}`.
O `challenge` é o que o app acabou de receber, então a prova não pode ser reaproveitada. O app só
apaga os dados se `revoked_sig` verificar com `server_sign_pub` fixada. Sem prova válida, trata
como erro de rede.

## 7. Diretório e certificados

### 7.1 `GET /v1/directory`

```json
{ "users": [ { "user_id": "uuid", "admin_label": "...", "display_name": "...", "status": "...",
               "devices": [ DeviceCert, ... ] } ] }
```

Lista todo usuário com `disabled_at IS NULL`, inclusive o próprio, com seus aparelhos **ativos**.
Usuário sem perfil ainda tem `display_name` vazio.

O app, para cada aparelho: monta `cert_bytes`, verifica `sig` com `server_sign_pub`, confere
`cert.user_id` e `cert.admin_label` iguais aos do usuário. Falha = descarta o aparelho e registra
alerta local. O app não recusa certificado por `expires_at` do relógio local (relógio pode estar
errado); quem filtra vencidos é o servidor.

Na tela, o nome principal é `admin_label` (assinado). `display_name` aparece como complemento.

### 7.2 `GET /v1/devices?ids=<uuid>,<uuid>,...` (rota nova)

Até 100 ids. Devolve certificados de qualquer aparelho, **inclusive revogados e vencidos**:
`{"devices": [ {"cert": DeviceCert, "revoked_at": ms|null} ]}`. Serve para verificar assinaturas
de mensagens e épocas antigas cujo autor saiu do diretório. `revoked_at` não é assinado: só informa.

### 7.3 Aviso de aparelho novo (confiança no primeiro uso)

O app guarda, por `user_id`, o conjunto de `sign_pub` já vistos. Quando o diretório traz um
`sign_pub` novo de um contato com quem há conversa, o app insere nessa conversa um aviso local:
"<admin_label> conectou um aparelho novo em <enrolled_at>". Quando um some: "<admin_label>
desconectou um aparelho". O aviso não bloqueia o envio. É a defesa contra aparelho fantasma
inserido por quem controla o servidor (ver `ameacas.md`).

Na primeira vez que o app vê um usuário (sem conjunto anterior), só registra. A comparação vale
também para o certificado obtido por `/v1/devices` (7.2); numa instalação nova, um aparelho antigo
do contato que só apareça no histórico gera o aviso, com a data antiga.

### 7.4 `PUT /v1/me/profile`

`{"display_name": "...", "status": "..."}` → 204. Limites em 2.3. Dispara `directory_changed` (11.5).
No máximo 5 por minuto por aparelho (`rate_limited`).

## 8. Conversas

### 8.1 `POST /v1/conversations`

`{"kind": "direct", "peer_user_id": "uuid"}` → 200 `Conversation`. Idempotente: se já existe conversa
direta entre os dois, devolve a mesma com `"created": false`. `peer_user_id` deve ser outro usuário
ativo. Dispara o evento `conversation` (11.5) para os aparelhos dos membros.

`Conversation`:

```json
{ "conversation_id": "uuid", "kind": "direct", "members": ["uuid", "uuid"],
  "latest_epoch": 0, "last_seq": 0, "created": true }
```

`latest_epoch` = 0 e `last_seq` = 0 quando ainda não há época ou mensagem.

Grupo (`kind: "group"`) tem ainda `chain_n`, `admin_label` (ou `null`) e `closed`
(`protocolo-grupos.md` §10.5). Nele `members` é só informativo: quem decide é a cadeia assinada.

Na v1 (só 1:1) os membros de uma conversa **nunca mudam**. O app grava os da primeira vez e recusa,
com aviso local na conversa, qualquer `members` diferente para o mesmo `conversation_id` (resposta
HTTP ou evento). Também recusa `POST /v1/conversations` cujo `members` não tenha o par pedido.

### 8.2 `GET /v1/conversations` (rota nova)

`{"conversations": [Conversation, ...]}` (sem `created`), só as que o usuário é membro.

## 9. Épocas

Grupos usam a declaração `group_epoch_bytes`, o `EpochItem` com `chain_n`/`chain_hash`, a validação
extra e o conjunto `S` tirado da cadeia (`protocolo-grupos.md` §5 e §10.3). Páginas de
`epochs/mine` param perto de 2 MiB (`has_more`).

### 9.1 Chave

`K` = 32 bytes de `randombytes_buf`, gerados pelo aparelho que cria a época. `epoch` é `u32`,
começa em 1 e sobe de 1 em 1 por conversa.

### 9.2 Compromisso

```
key_commitment = BLAKE2b-256( "direct/v1/epoch-key\0" || conversation_id(16) || u32(epoch) || K(32) )   # 72 bytes de entrada
```

Sealed box não autentica quem selou. Sem o compromisso, o servidor poderia trocar o embrulho de um
aparelho por uma chave que ele conhece e ler o que esse aparelho enviasse depois. O compromisso
vai na declaração assinada pelo criador, e todo destinatário confere.

### 9.3 Declaração assinada

```
recipients     = device_id de todos os destinatários, ordem crescente por bytes, sem repetição
epoch_bytes    = "direct/v1/epoch\0" || conversation_id(16) || u32(epoch) || creator_device_id(16)
              || key_commitment(32) || escrow_pub(32) || u32(n) || recipients[0](16) || ... || recipients[n-1](16)
                                                                                         # 120 + 16n bytes
epoch_sig      = Ed25519_sign(sign_seed do criador, epoch_bytes)
```

`escrow_pub` é a fixada no app do criador. O verificador monta os bytes com a **sua** `escrow_pub`
fixada: se o criador usou outra, a assinatura não confere.

### 9.4 Embrulhos

```
wrapped_key(destinatário) = crypto_box_seal(K, kex_pub do destinatário)      # 80 bytes
escrow_wrap               = crypto_box_seal(K, escrow_pub)                  # 80 bytes
```

Texto claro = só os 32 bytes de `K`. Contexto (conversa, época) vem do compromisso.

### 9.5 Quem cria e quando

Antes de enviar uma mensagem na conversa C, o app calcula:

- `S` = `device_id` de todos os aparelhos no diretório (já verificados, 7.1) de todos os membros de C.
- `L` = `latest_epoch` de C (de `GET /v1/conversations` ou do último evento).

Cria a época `L + 1` se qualquer um vale:
1. `L = 0` (conversa sem época);
2. a lista `recipients` da época `L` é diferente de `S`;
3. o app não tem `K` da época `L` (ainda não recebeu ou não conseguiu validar).

Ou seja: quem envia a próxima mensagem depois de entrar ou sair aparelho ou membro cria a época.
Se dois aparelhos criam ao mesmo tempo, o servidor aceita o primeiro e o outro recebe 409.

### 9.6 `POST /v1/conversations/{id}/epochs`

```json
{
  "epoch": 2,
  "creator_device_id": "uuid",
  "key_commitment": "<b64u 32>",
  "recipients": ["uuid", "uuid"],
  "wraps": [ {"device_id": "uuid", "wrapped_key": "<b64u 80>"} ],
  "escrow_wrap": "<b64u 80>",
  "signature": "<b64u 64>"
}
```

O servidor, numa transação:
1. `creator_device_id` = aparelho autenticado, e o usuário dele é membro. Senão 403 `forbidden`.
2. `epoch = latest_epoch + 1`. Senão 409 `epoch_conflict` com `latest_epoch` no corpo do erro.
3. `recipients` em ordem crescente estrita e **igual** ao conjunto de aparelhos ativos de todos os
   membros agora. Senão 409 `device_set_changed`.
4. Exatamente um item em `wraps` por destinatário, cada `wrapped_key` com 80 bytes; `escrow_wrap`
   com 80 bytes. Senão 400.
5. Monta `epoch_bytes` com a `escrow_pub` do servidor e verifica `signature` com o `sign_pub` do
   criador. Falha: 400 `bad_signature`.
6. Trava `epoch_key_wraps` contra outras escritas até o fim da transação (um `wrap_id` menor nunca
   faz commit depois de um maior, e o cursor de 9.7 não pula embrulho). Grava `epochs` (com
   `key_commitment`, `recipients`, `signature`), uma linha em `epoch_key_wraps`
   por destinatário e uma de escrow (`recipient_device_id` NULL). Cada linha de aparelho recebe um
   `wrap_id` crescente (bigserial).
7. 201 `{"epoch": 2}`. Envia o evento `epoch` (11.5) a cada destinatário conectado.

O servidor não confere `key_commitment` (não tem `K`).

Erro 409: o app atualiza diretório e conversas, recalcula e tenta de novo, até 3 vezes.

### 9.7 `GET /v1/epochs/mine?after=<wrap_id>&limit=<n>`

`after` padrão 0, `limit` padrão e máximo 500. Ordem crescente de `wrap_id`.

```json
{ "items": [ EpochItem ], "has_more": false }
```

`EpochItem`:

```json
{
  "wrap_id": 17,
  "conversation_id": "uuid", "epoch": 2, "creator_device_id": "uuid",
  "key_commitment": "<b64u 32>", "recipients": ["uuid", "..."], "signature": "<b64u 64>",
  "wrapped_key": "<b64u 80>"
}
```

Só embrulhos com `recipient_device_id` = este aparelho. Embrulho de escrow nunca sai do servidor.
O app guarda o maior `wrap_id` processado. Ao receber mensagem de época cuja chave não tem, busca
de novo a partir de `after=0`, uma vez por sessão.

### 9.8 Validação no app

Para cada `EpochItem`, na ordem:
1. Certificado do criador (diretório ou `/v1/devices`), verificado com `server_sign_pub`. O
   `user_id` dele é membro da conversa.
2. Monta `epoch_bytes` com a `escrow_pub` fixada e verifica `signature`.
3. `K = crypto_box_seal_open(wrapped_key, kex_pub, kex_sk)`; deve ter 32 bytes.
4. Recalcula `key_commitment` e compara em tempo constante (`sodium_memcmp`).
5. Guarda `K` para `(conversation_id, epoch)`.

Qualquer falha: descarta o item e registra alerta local. **Não** exige que o próprio aparelho
esteja em `recipients`: embrulhos do `rewrap` (13.3) valem para épocas antigas, porque o
compromisso assinado pelo criador garante que a chave é a certa.

## 10. Mensagens

### 10.1 Texto claro

JSON UTF-8. Única forma na v1:

```json
{"type":"text","text":"Olá, João!"}
```

`text`: 1 a 12000 bytes UTF-8. Outros `type`: o app mostra "mensagem não suportada nesta versão".
Campos desconhecidos são ignorados.

### 10.2 Preenchimento

`padded = sodium_pad(texto_claro, 256)`: acrescenta `0x80` e zeros até o próximo múltiplo de 256.
Sempre acrescenta pelo menos 1 byte (texto de 256 bytes vira 512). `len(padded)` entre 256 e
16384. Esconde o tamanho exato do Cloudflare e do servidor.

### 10.3 Cabeçalho, AAD e cifra

```
message_id = 16 bytes aleatórios (UUIDv4), gerado uma vez por mensagem; reenvio usa o mesmo
sent_at    = relógio do remetente, ms
header     = conversation_id(16) || u32(epoch) || sender_device_id(16) || message_id(16) || u64(sent_at)   # 60 bytes
aad        = "direct/v1/msg\0" || header                                                                 # 74 bytes
nonce      = 24 bytes aleatórios
ciphertext = XChaCha20-Poly1305-IETF-Encrypt(key=K, nonce, plaintext=padded, ad=aad)                    # len(padded) + 16
```

`sender_device_id` no AAD impede que outro membro (que também tem `K`) tire a assinatura e
assine a mensagem como sua: a decifração falharia.

### 10.4 Assinatura

```
sig_bytes = "direct/v1/msg-sig\0" || header(60) || nonce(24) || u32(len(ciphertext)) || ciphertext   # 106 + len bytes
signature = Ed25519_sign(sign_seed do remetente, sig_bytes)
```

Assina o texto cifrado: o servidor confere a autoria sem ler o conteúdo.

### 10.5 Forma no fio

Envio (dentro do quadro `send`, 11.4):

```json
{ "conversation_id": "uuid", "epoch": 1, "sender_device_id": "uuid", "message_id": "uuid",
  "sent_at": 1795600000123, "nonce": "<b64u 24>", "ciphertext": "<b64u>", "signature": "<b64u 64>" }
```

Armazenada e entregue (`Message`): os mesmos campos mais `"seq": n` e `"created_at": ms`, ambos
do servidor. `seq` é `u64`, começa em 1 e sobe de 1 em 1 por conversa.

### 10.6 O servidor, ao receber `send`

1. `sender_device_id` = aparelho autenticado; usuário dele é membro. Senão `forbidden`.
2. Tamanhos: `nonce` 24, `signature` 64, `len(ciphertext) - 16` múltiplo de 256 entre 256 e 16384.
   Senão `bad_request`.
3. Já existe `(conversation_id, message_id)` do mesmo remetente: responde `ack` com o `seq`
   original e não grava de novo (reenvio após queda).
4. `epoch = latest_epoch` **e** os `recipients` dessa época são iguais aos aparelhos ativos dos
   membros agora. Senão `epoch_required` com `latest_epoch`.
5. Verifica `signature` com o `sign_pub` do remetente. Falha: `bad_signature`.
   - Grupo encerrado: `group_closed` (conferido depois do passo 3, então reenvio ainda recebe `ack`).
6. Numa transação: `seq = last_seq + 1`, `created_at = agora`, grava.
7. `ack` ao remetente e `message` a todas as outras conexões no escopo (11.3), inclusive outros
   aparelhos do remetente.

O passo 4 garante que aparelho revogado ou vencido não recebe chave de mensagem nova: o próximo
envio força uma época sem ele.

Tabela `messages` do PLANO 4.3 ganha `message_id` (único por conversa) e `sent_at`.

### 10.7 O app, ao receber uma `Message`

1. Ignora se já tem `(conversation_id, message_id)`.
2. Busca `K` de `(conversation_id, epoch)`. Sem `K`: guarda cifrada como "aguardando chave" e tenta
   de novo após cada `GET /v1/epochs/mine`.
3. Certificado de `sender_device_id` (diretório ou `/v1/devices`), verificado; `user_id` dele é
   membro (em grupo: `membro_em(dono, chain_n da época)`).
4. Verifica `signature` sobre `sig_bytes`.
5. Decifra com `aad`; `sodium_unpad(…, 256)`; JSON válido.
6. Exibe com `sent_at` (do remetente) e ordena por `seq`.

Falha em 3, 4 ou 5: descarta e registra alerta local, sem conteúdo.

### 10.8 Histórico — `GET /v1/conversations/{id}/messages?after=<seq>&limit=<n>`

Só membros. `after` padrão 0, `limit` padrão 200, máximo 500. Ordem crescente de `seq`.
`{"messages": [Message, ...], "has_more": false}`.

Com `before=<seq>`: as `limit` mais novas com `seq < before` (e `> after`), ainda em ordem
crescente; `has_more` = há mais antigas. Em grupo, mensagem de autor inativo vem selada, sem texto
cifrado (`protocolo-grupos.md` §7.2).

## 11. WebSocket — `wss://<host>/v1/ws`

### 11.1 Quadros

- Só quadros de texto, um objeto JSON por quadro, até 64 KiB. Quadro binário ou JSON inválido:
  fecha com 4000.
- Todo quadro tem `"type"`. Pedidos do cliente que esperam resposta levam `"req_id"` (texto de
  1 a 64 caracteres, escolhido pelo cliente); a resposta repete o `req_id`.
- O token nunca vai na URL.

### 11.2 Autenticação

Primeiro quadro do cliente, em até 10 s (senão fecha com 4001):

```json
{"type": "auth", "access_token": "<b64u 32>", "conversations": null}
```

- `conversations: null` (ou ausente): escopo = todas as conversas do usuário. Usado pelo app principal.
- `conversations: ["uuid"]` (1 a 10 ids): escopo = só essas. Usado pelo chat flutuante (PLANO 9).
  Conversa da qual o usuário não é membro: fecha com 4000.

Resposta:

```json
{"type": "ready", "device_id": "uuid", "server_time": 1795600000000, "token_expires_at": 1795600900000}
```

No máximo 4 conexões simultâneas por aparelho; a quinta fecha a mais antiga com 4009.

### 11.3 Escopo

Eventos `message` e `epoch` só chegam de conversas no escopo. `conversation` só chega ao escopo
"todas". `directory_changed` chega a todos.

Com escopo restrito o cliente não avança o `wrap_id` local pelos eventos `epoch` (épocas de outras
conversas não chegam e seriam puladas), nem envia pendências fora do escopo.

### 11.4 Cliente → servidor

| `type` | Campos | Resposta |
|--------|--------|----------|
| `auth` | ver 11.2 | `ready` |
| `ping` | `ts` (ms do cliente) | `pong` com o mesmo `ts` |
| `send` | `req_id`, `message` (10.5) | `ack` ou `error` |

`ack`:

```json
{"type": "ack", "req_id": "r1", "conversation_id": "uuid", "message_id": "uuid", "seq": 42, "created_at": 1795600000456}
```

`error`:

```json
{"type": "error", "req_id": "r1", "code": "epoch_required", "message": "...", "latest_epoch": 3}
```

Com `epoch_required`: o app busca `/v1/epochs/mine` e o diretório, aplica 9.5 e reenvia com o mesmo
`message_id`, cifrando de novo com a `K` da época nova (nonce novo). Até 3 tentativas.

### 11.5 Servidor → cliente (eventos)

| `type` | Campos | Quando |
|--------|--------|--------|
| `message` | `message`: `Message` | mensagem nova no escopo |
| `epoch` | `item`: `EpochItem` | época nova com embrulho para este aparelho |
| `conversation` | `conversation`: `Conversation` | conversa nova com o usuário |
| `directory_changed` | `user_id` | perfil mudou, aparelho entrou, foi revogado ou venceu, usuário desativado |
| `group_change` | `conversation_id`, `change`, `meta` | registro novo na cadeia de um grupo (`protocolo-grupos.md` §10.5) |
| `member_access` | `user_id`, `active`, `at`, `conversations` | membro de grupo perdeu ou recuperou o acesso (§7.3 de grupos) |

`directory_changed` é agregado: no máximo um a cada 3 s por conexão. A primeira mudança sai na hora;
as seguintes dentro do intervalo viram um único quadro, com o `user_id` da última. O app deve
buscar o diretório inteiro, sem confiar no `user_id` para saber o que mudou.

### 11.6 Ping

Cloudflare fecha WebSocket ocioso em ~100 s.
- Cliente envia `ping` a cada 30 s. Sem `pong` em 10 s: fecha e reconecta.
- Servidor responde `pong` na hora. Sem nenhum quadro do cliente por 75 s: fecha com 4008.
- Não usar ping de controle do WebSocket (o `web_socket_channel` não expõe igual nas duas
  plataformas). O ping é o quadro JSON acima.

### 11.7 Fechamento

| Código | Motivo | O app faz |
|--------|--------|-----------|
| 1001 | servidor reiniciando | reconecta com espera |
| 4000 | erro de protocolo | registra, reconecta com espera |
| 4001 | token inválido, vencido ou `auth` atrasado | login (6.1–6.2) e reconecta |
| 4003 | aparelho revogado ou usuário desativado | faz login para obter a prova (6.4); não reconecta |
| 4004 | aparelho vencido | mostra "acesso vencido, peça um token novo"; não reconecta |
| 4008 | ocioso | reconecta |
| 4009 | substituída por conexão mais nova | não reconecta esta |
| 4029 | limite de taxa | reconecta com espera |

O servidor fecha com 4001 quando `token_expires_at` passa. O app renova o token antes e reconecta.

Espera entre tentativas: 1 s, 2 s, 4 s ... até 60 s, com variação aleatória de ±20%. Volta a 1 s
após `ready`.

### 11.8 Sequência ao abrir o app (fluxo 6.3)

1. Desbloqueio local (senha).
2. Login (6.1–6.2).
3. Abre o WebSocket, envia `auth`, espera `ready`. Guarda os eventos que chegam num buffer.
4. `GET /v1/directory` e atualiza avisos de aparelho (7.3).
5. `GET /v1/epochs/mine?after=<maior wrap_id local>` até `has_more = false`; valida (9.8).
6. `GET /v1/conversations`; para cada uma com `last_seq` maior que o local, baixa o histórico (10.8).
7. Aplica o buffer do passo 3, descartando `seq` já vistos.

O chat flutuante faz o mesmo com escopo de uma conversa e pula o passo 6 para as demais.

## 12. Revogação e vencimento (fluxo 6.4, passo 2)

`direct-admin device revoke <id>`, numa transação:
1. `revoked_at = agora`.
2. Apaga `access_tokens` e `auth_challenges` do aparelho.
3. Avisa o `directd` (ex.: `NOTIFY device_revoked` do Postgres), que fecha os WebSockets do
   aparelho com 4003 e envia `directory_changed` a todos.

`user disable` faz o mesmo para todos os aparelhos do usuário. Vencimento (`expires_at`) tem o
mesmo efeito na próxima requisição; o fechamento do WebSocket acontece no máximo quando o token de
acesso vence (15 min).

O `NOTIFY` enviado enquanto o `directd` não está escutando se perde; por isso, ao refazer o
`LISTEN`, ele reconfere os aparelhos conectados e fecha os revogados.

Efeitos:
- O aparelho não autentica mais e não recebe nada novo.
- O próximo envio em qualquer conversa do dono recebe `epoch_required` (10.6, passo 4) e cria
  época sem ele.
- Embrulhos antigos dele ficam no banco, mas o servidor não os entrega a ninguém.
- A transição do dono (ativo/inativo) é gravada em `user_access_events`. O `directd` também varre
  os vencimentos a cada minuto.
- `POST /v1/devices/self-revoke`: o próprio aparelho se revoga sem token de acesso, com a revogação
  pré-assinada (`protocolo-grupos.md` §8).
- O app revogado que se conectar recebe a prova (6.4) e apaga banco local, chaves e Keychain/Keystore.
  Aparelho que nunca mais se conectar mantém o que já tinha localmente (ver `ameacas.md`).

## 13. Escrow (D5 = A)

### 13.1 Arquivo da chave

```
header = "direct-escrow-v1"(16 bytes ASCII, sem 0x00) || u32(opslimit) || u32(memlimit_kib) || salt(16) || nonce(24)   # 64 bytes
chave  = Argon2id(senha UTF-8 sem normalização, salt, t=opslimit, m=memlimit_kib KiB, p=1, saída 32 bytes)
arquivo = header || XChaCha20-Poly1305-IETF-Encrypt(key=chave, nonce, plaintext=escrow_sk(32), ad=header)            # 112 bytes
```

- A chave do moderador usa o mesmo formato, com magia `direct-modkey-v1`.
- Valores ao gerar: `opslimit = 3`, `memlimit_kib = 262144` (256 MiB), `salt` e `nonce` aleatórios.
- Em libsodium: `crypto_pwhash(32, senha, salt, opslimit, memlimit_kib * 1024, ALG_ARGON2ID13)`. Em
  Go: `argon2.IDKey(senha, salt, opslimit, memlimit_kib, 1, 32)`.
- Ao ler: recusa se `opslimit > 10` ou `memlimit_kib > 1048576` (evita arquivo que trava a máquina).
- Senha: mínimo recomendado de 16 caracteres; a CLI pede duas vezes ao criar.

### 13.2 `direct-admin escrow init --out <arquivo>`

1. Recusa se `server_keys` já tem `escrow_pub` (sem troca de chave na v1).
2. Gera `escrow_sk` (32 bytes), `escrow_pub = X25519(escrow_sk, base)`.
3. Pede a senha, grava o arquivo (modo 0600), zera `escrow_sk` e a chave da memória.
4. Grava `escrow_pub` em `server_keys` e imprime `escrow_pub` e o código de verificação (4.3).

Gerar no servidor faz a chave privada passar pela memória dele uma vez. Para evitar, rodar o
`init` numa máquina offline e registrar só a pública no servidor (a F3 decide a forma; o formato
do arquivo é o mesmo).

### 13.3 `direct-admin escrow rewrap --device <id> --key <arquivo>` (fluxo 6.4, passo 4)

`kex_pub` e a lista de membros vêm do banco, que quem invadir o servidor pode alterar. Por isso o
comando confirma o aparelho por outro canal, só usa o que a assinatura do criador cobre e mostra o
que vai fazer antes de gravar.

1. O aparelho alvo deve estar ativo.
2. Mostra o **código do aparelho** (13.4) e pede confirmação (`sim`). O moderador confere com o
   código em Ajustes no aparelho novo, pessoalmente ou por telefone. Sem `sim`: aborta.
3. Lê o arquivo, pede a senha, decifra `escrow_sk`. Confere `X25519(escrow_sk, base)` = `escrow_pub`
   do servidor. Diferente: aborta.
4. Escolhe as conversas: entre as que o dono do aparelho é membro segundo o banco, só as que têm
   **alguma época com um aparelho dele (inclusive revogado ou vencido) em `recipients` e assinatura
   do criador válida**. Delas, entram todas as épocas com embrulho de escrow e sem embrulho para o
   aparelho, inclusive as criadas enquanto o usuário não tinha aparelho ativo (os membros de uma
   conversa direta nunca mudam, 8.1). As épocas das demais conversas são contadas como "fora"; as
   que citam o usuário com assinatura inválida saem como falha. Esta regra não vale para grupos:
   neles entram só as épocas que `pode_reembrulhar` permite na cadeia verificada, listadas com o
   registro que autoriza (`protocolo-grupos.md` §5.4).
5. Lista as conversas (id, outros membros, número de épocas) e pede nova confirmação (`sim`).
6. Numa transação, reconfere que o aparelho segue ativo com as mesmas `sign_pub` e `kex_pub`
   mostradas e, para cada época escolhida das conversas listadas:
   1. `K = crypto_box_seal_open(escrow_wrap, escrow_pub, escrow_sk)`, 32 bytes.
   2. Recalcula `key_commitment` (9.2) e compara com o gravado.
   3. Monta `epoch_bytes` (9.3) e verifica `signature` com o `sign_pub` do criador.
   4. Qualquer falha: registra a época na saída e pula. Não aborta o resto.
   5. Grava `crypto_box_seal(K, kex_pub confirmada)` em `epoch_key_wraps` com `wrap_id` novo.
7. Zera `escrow_sk` e as `K` da memória. Imprime: épocas reembrulhadas, puladas, fora e com falha.

O que sobra: a ligação entre `device_id` e usuário, e a `sign_pub` do criador, vêm do banco. Quem
reescrever as duas pode fazer uma conversa alheia passar no passo 4; a lista do passo 5 é a última
conferência. Como basta uma época para liberar a conversa inteira, o mesmo vale se um app recém-
instalado de um participante receber do servidor membros trocados (ainda sem os ter fixado) e criar
uma época incluindo o usuário.

O app recebe os embrulhos no próximo `GET /v1/epochs/mine` (ao abrir ou reconectar) e valida
como em 9.8. Depois, `GET /v1/conversations/{id}/messages?after=0` devolve o histórico.

### 13.4 Código do aparelho

```
dg = BLAKE2b-256( "direct/v1/device-code\0" || sign_pub(32) || kex_pub(32) )      # 86 bytes de entrada
código = os mesmos 4 grupos de 5 dígitos de 4.3, a partir de dg
```

O app mostra o código do próprio aparelho em Ajustes. Vetores em `vetores/chaves.json`
(`codigo_aparelho`).

## 14. Códigos de erro

| Código | HTTP | Onde |
|--------|------|------|
| `bad_request` | 400 | formato, tamanho, base64url, limites |
| `bad_signature` | 400 | assinatura de época ou mensagem inválida |
| `unauthorized` | 401 | token de acesso ausente, inválido ou vencido |
| `invite_invalid` | 401 | cadastro com convite inexistente, usado, vencido ou assinaturas inválidas |
| `auth_failed` | 401 | desafio inválido ou assinatura de login inválida |
| `device_revoked` | 401 | aparelho revogado ou usuário desativado (no `verify`, com `revoked_sig`) |
| `device_expired` | 401 | aparelho vencido |
| `forbidden` | 403 | não é membro, não é o criador/remetente autenticado |
| `not_found` | 404 | conversa inexistente |
| `key_in_use` | 409 | `sign_pub` já cadastrado |
| `epoch_conflict` | 409 | número de época já existe |
| `device_set_changed` | 409 | destinatários diferentes dos aparelhos ativos |
| `too_large` | 413 | blob acima de 10 MiB (18.4) |
| `epoch_required` | — (WebSocket) | envio exige época nova ou mais recente |
| `rate_limited` | 429 | limite de taxa |
| `chain_invalid` | 400 | registro de grupo inválido (`reason`) |
| `chain_conflict` | 409 | posição da cadeia diferente do topo (`chain_n`) |
| `group_closed` | 409 / WebSocket | grupo encerrado |
| `group_exists` | 409 | id de grupo já usado |
| `sender_inactive` | 403 | blob ou salvamento de autor inativo |
| `device_limit` | 409 | 4 aparelhos ativos no usuário (`/v1/enroll`) |

Limites de taxa recomendados: `/v1/enroll` 5/min por IP; `/v1/auth/*` 30/min por IP; `verify`
também 10/min por par (IP, aparelho); `send` 10/s por aparelho com rajada de 30; por aparelho:
perfil 5/min, criação de época 30/min, upload de blob 20/min, download de blob 120/min, registro de
salvamento 20/min. `challenge` não tem limite por aparelho: o `device_id` é público e nada foi
provado, então um limite desses deixaria um terceiro trancar o login alheio.

## 15. Mudanças em relação ao PLANO (seções 4.2 e 4.3)

Rotas novas: `GET /v1/server-info`, `GET /v1/conversations`, `GET /v1/devices`.

Modelo de dados:
- `enrollment_tokens.token_hash` → `invite_pub` (32 bytes, único).
- `devices`: `cert_sig`.
- `auth_challenges (device_id, challenge, expires_at)`: nova.
- `server_keys (server_sign_pub, escrow_pub)`: nova (a semente de assinatura fica em arquivo, não no banco).
- `epochs`: `key_commitment`, `recipients` (lista de UUID na ordem de 9.3), `signature`.
- `epoch_key_wraps`: `wrap_id` (bigserial). Escrow continua com `recipient_device_id` NULL.
- `messages`: `message_id` (único por conversa), `sent_at`.

## 16. Vetores de teste

`docs/vetores/`:

| Arquivo | Conteúdo |
|---------|----------|
| `chaves.json` | sementes e chaves fixas: servidor, escrow, aparelhos A (Ana), B e C (João; C é o aparelho novo) |
| `convite.json` | URI do QR, `invite_pub`, código de verificação, URIs que devem ser recusadas |
| `cadastro.json` | `enroll_bytes`, `invite_sig`, `proof`, requisição JSON, certificados de A, B e C, pontos X25519 de ordem baixa |
| `login.json` | `auth_bytes`, assinatura, hash do token de acesso, prova de revogação |
| `epoca.json` | época 1 da conversa A↔B: `K`, compromisso, declaração, embrulhos para A, B e escrow |
| `anexo.json` | blob cifrado de uma imagem, mensagem `image` de A que o referencia, casos que devem falhar, texto do EXIF de salvamento (seção 18) |
| `mensagem.json` | mensagem de A: texto claro, preenchimento, cabeçalho, AAD, cifra, assinatura, quadro `send`, casos que devem falhar, casos de preenchimento |
| `escrow.json` | arquivo da chave de escrow (Argon2id) e `rewrap` da época 1 para C |
| `grupos/*.json` | cadeia, épocas, seladas, revogação e QR com a chave do moderador (`protocolo-grupos.md` §13) |

Binário em hexadecimal minúsculo, salvo campos terminados em `_b64u` e os exemplos de JSON do fio.

Sealed box usa chave efêmera aleatória, então em Dart não dá para reproduzir os bytes selados pela
API normal: o teste é abrir `wrapped_key` e obter `K`. O gerador e o conferidor reconstroem a
selagem com a chave efêmera fixa (`eph_sk`) para provar que Go e libsodium fazem a mesma conta.

Gerar (Go em Docker, saída idêntica a cada execução):

```bash
docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp -e GOCACHE=/tmp/gocache -v "$PWD/docs/vetores:/v" -w /v/gerador golang:1.25-alpine go run . /v
```

Conferir com libsodium (mesma biblioteca do `sodium_libs`):

```bash
python3 docs/vetores/conferir.py
```

Testes que as fases devem ter:
- **F2/F3 (Go):** teste que lê cada JSON e refaz bytes, assinaturas, cifras e aberturas.
- **F5b (Go e Dart):** o mesmo com `anexo.json` (abrir o blob, conferir SHA-256, abrir a mensagem `image`).
- **F5 (Dart):** o mesmo com `sodium_libs`, mais abrir todo `wrapped_key` e recusar todo caso de
  `deve_falhar` e de `qr_invalidos`.

## 17. Mapa dos fluxos do PLANO

| Fluxo (PLANO 6) | Seções aqui |
|-----------------|-------------|
| 6.1 Cadastro | 4 (QR), 5 (enroll), 7.4 (perfil) |
| 6.2 Login | 6.1–6.3 |
| 6.3 Mensagens | 9 (épocas), 10 (mensagens), 11 (WebSocket, sequência 11.8, escopo do chat flutuante 11.2) |
| 6.4 Aparelho perdido ou trocado | 12 (revogação), 4–5 (cadastro do novo), 13.3 (rewrap), 9.8 e 10.8 (app baixa e decifra) |
| PLANO 15 Imagens | 18 (anexos, blobs, salvamento) |
| 6.5 Esqueceu a senha | local no app (PLANO 7); depois 6.4 a partir do passo 2 |
| PLANO 16 Grupos | `protocolo-grupos.md` |

## 18. Anexos (imagens)

PLANO 15 (D8). Imagem = **blob** cifrado, guardado no servidor, mais uma mensagem E2E (seção 10)
que leva a chave. Como a chave vai dentro da mensagem, escrow (13) e recuperação de histórico
cobrem imagens sem mudança. O servidor nunca vê a imagem nem a chave.

### 18.1 Mensagem `image`

Texto claro da seção 10.1 com outro `type`. Binários em base64url sem `=` (2.2).

```json
{"type":"image","blob_id":"<uuid>","key":"<b64u 32>","sha256":"<b64u 32>",
 "mime":"image/jpeg","w":1536,"h":2048,"thumb":"<b64u>"}
```

| Campo | Regra |
|-------|-------|
| `blob_id` | UUID devolvido por `POST /v1/blobs` (18.4) |
| `key` | 32 bytes aleatórios, uma chave nova por imagem. Nunca reutilizar entre imagens |
| `sha256` | SHA-256 do blob inteiro (18.2), 32 bytes |
| `mime` | só `image/jpeg` na v1 |
| `w`, `h` | largura e altura em pixels depois da rotação, 1 a 4096. O remetente envia no máximo 2048 |
| `thumb` | miniatura JPEG, lado maior 96 px ou menos, no máximo 6144 bytes (8192 caracteres em base64url) |

O texto claro (JSON) cabe em 16383 bytes, o limite do preenchimento (10.2); com `thumb` de 6144
bytes sobra folga. `thumb` serve para mostrar a conversa sem baixar o blob. Ela fica em memória e
no banco cifrado, como qualquer mensagem. Receptor: recusa a mensagem como "não suportada" se
algum campo faltar, tiver tamanho errado ou `mime` diferente; ignora campos desconhecidos.

### 18.2 Blob

```
key        = 32 bytes aleatórios (campo key da mensagem)
nonce      = 24 bytes aleatórios
aad        = "direct/v1/blob\0" || conversation_id(16)                              # 31 bytes
ciphertext = XChaCha20-Poly1305-IETF-Encrypt(key, nonce, plaintext = bytes do JPEG, ad = aad)   # len(jpeg) + 16
blob       = nonce(24) || ciphertext                                                # len(jpeg) + 40 bytes
sha256     = SHA-256(blob)
```

Sem preenchimento: o servidor e o Cloudflare enxergam o tamanho aproximado da foto. O AAD prende o
blob à conversa. Tamanho do blob: 41 a 10485760 bytes (10 MiB). O remetente reduz o JPEG até caber.

### 18.3 Preparo da imagem no remetente

1. Decodificar a imagem (câmera ou galeria) e aplicar a orientação EXIF aos pixels.
2. Reduzir para no máximo 2048 px no lado maior (nunca ampliar) e recomprimir em JPEG, qualidade
   recomendada 85. Gerar o JPEG a partir dos pixels: **nenhum** EXIF, XMP, IPTC, miniatura ou GPS
   do arquivo original pode sobrar.
3. Gerar `thumb` do mesmo jeito (96 px, qualidade recomendada 50).
4. Cifrar (18.2), enviar o blob (18.4), enviar a mensagem (seção 10, `type` `image`).
5. Apagar o arquivo temporário do seletor logo após ler os bytes. Em claro, a imagem existe só na
   memória.

### 18.4 `POST /v1/blobs?conversation_id=<uuid>`

Autenticado (6.3). `Content-Type: application/octet-stream`. Corpo = o blob (18.2), sem JSON, sem
base64. Só membro ativo da conversa. O servidor não abre o blob.

Resposta `201`:

```json
{ "blob_id": "uuid", "size": 123456, "sha256": "<b64u 32>" }
```

O servidor gera `blob_id` (UUIDv4) e calcula o SHA-256 do corpo recebido. O app deve comparar com o
seu próprio hash e só então mandar a mensagem. O blob não é apagado quando não há mensagem que o
use (upload órfão). `direct-admin media prune --older <prazo>` (padrão 30d, mínimo 24h) apaga os
blobs sem nenhuma mensagem posterior do mesmo aparelho na mesma conversa. O servidor não lê o
`blob_id` (vai cifrado), então um órfão seguido de outra mensagem fica.

Cota: 1 GiB por usuário nas últimas 24 h, somando os aparelhos.

| Erro | Quando |
|------|--------|
| 400 `bad_request` | `conversation_id` ausente ou malformado, corpo com menos de 41 bytes |
| 403 `forbidden` | não é membro |
| 404 `not_found` | conversa inexistente |
| 413 `too_large` | corpo acima de 10485760 bytes |
| 429 `rate_limited` | limite de 20 envios por minuto por aparelho, rajada 20; ou cota diária esgotada |

### 18.5 `GET /v1/blobs/{id}`

Autenticado. Só membro ativo da conversa a que o blob pertence. `200`, `Content-Type:
application/octet-stream`, `Cache-Control: no-store`, corpo = o blob. `404 not_found` se o blob não
existe; `403 forbidden` se o usuário não é membro; `403 sender_inactive` se a conversa é grupo e
quem enviou o blob está inativo. O app confere `SHA-256(corpo)` contra o campo
`sha256` da mensagem **antes** de decifrar; diferente = descarta e mostra "imagem indisponível".
Falha ao decifrar também descarta. Nenhum cache em disco em claro (nem o do cliente HTTP).
`429 rate_limited`: mais de 120 downloads por minuto por aparelho, mais de 4 em andamento por
usuário ou mais de 16 no servidor.

### 18.6 `POST /v1/media/saves`

Registro de que alguém salvou uma foto na galeria (PLANO 15). Autenticado. Corpo JSON:

```json
{ "conversation_id": "uuid", "seq": 42 }
```

Em grupo, mensagem de autor inativo: `403 sender_inactive`.

O servidor confere: membro ativo da conversa (`403 forbidden`); existe a mensagem
`(conversation_id, seq)` (`404 not_found`). Grava uma linha em `media_saves` a cada chamada (salvar
duas vezes gera dois registros), com `user_id` e `device_id` do token, e responde `201`:

```json
{ "save_id": "uuid", "saved_at": 1795600123456, "user_id": "uuid", "device_id": "uuid" }
```

O servidor não sabe se a mensagem é uma imagem nem o que ela contém, só que o par `(conversa,
seq)` foi salvo. Limite: 20 por minuto por aparelho (`rate_limited`).

O app recusa (e não salva) resposta cujo `user_id` ou `device_id` não sejam os dele; o EXIF usa os
ids locais.

O app só grava na galeria **depois** de receber a resposta (sem conexão, não salva). A foto salva é
a imagem decifrada, com **marca d'água visível** (D10) e EXIF novo, nesta ordem: obtém o `save_id`,
aplica a marca, grava o EXIF. A marca existe só na cópia da galeria; a visualização no app não a tem.

Marca: o texto `<rótulo> · <data UTC> · <save_id curto>` (rótulo = `Artist`; data como em `<UTC>`
abaixo; `save_id curto` = 8 primeiros caracteres), repetido em diagonal (cerca de 30°) pela imagem
inteira, branco com sombra, 50% opaco, corpo da letra ≈ 1/24 do lado menor. A fonte do app é só
ASCII: acentos saem sem acento e `·` vira `|` no desenho. O JPEG é recomprimido (qualidade 92) a
partir dos pixels e o EXIF vem depois. A foto salva é o JPEG com EXIF novo:

| Tag EXIF | Valor |
|----------|-------|
| `Artist` | rótulo do usuário (`admin_label` do certificado do aparelho) |
| `ImageDescription` | `Direct save_id=<save_id> user=<user_id> device=<device_id> at=<UTC>` |
| `UserComment` | igual a `ImageDescription` |

`<UTC>` = `saved_at` da resposta, em ISO 8601 UTC, segundos, sufixo `Z`, sem milissegundos
(`2026-11-24T18:30:05Z`). Todos os UUID em texto minúsculo (2.2). O EXIF some se a foto passar por editor ou rede social; vale só para o arquivo original.

### 18.7 Tabelas

```
blobs(id uuid PK, conversation_id, uploader_device_id, size, sha256, data bytea, created_at)
media_saves(save_id uuid PK, conversation_id, seq, user_id, device_id, saved_at)
```

`blobs.data` é `bytea` no PostgreSQL (mesmo volume cifrado do banco, entra no `pg_dump` e no backup
`age`, apaga junto com a conversa). Não há arquivo avulso a sincronizar. `media_saves` tem chave
estrangeira para `(conversation_id, seq)` de `messages`.

### 18.8 Ameaças

| Ameaça | Resposta |
|--------|----------|
| Servidor ou invasor lê imagens | Só vê blob cifrado; a chave está na mensagem E2E |
| Servidor troca o blob | SHA-256 da mensagem (assinada) e a tag AEAD detectam |
| Não membro baixa blob | 403; `blob_id` é aleatório de 128 bits e a rota exige token |
| Foto vaza da galeria do aparelho | EXIF com `save_id` ligado a quem salvou; só o arquivo original (PLANO 14) |
| Usuário salva sem registro | Cliente adulterado pode: a foto já estava legível na tela. O registro cobre o app legítimo |
