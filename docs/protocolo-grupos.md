# Protocolo de grupos — Direct v1 (delta)

Especificação dos grupos como **delta** sobre `docs/protocolo.md`. Tudo o que este documento
não muda continua valendo como está lá: primitivas (§1), codificação (§2), certificados (§5.3),
épocas (§9), mensagens (§10), WebSocket (§11), escrow (§13). Referências `§n` sem arquivo apontam
para `docs/protocolo.md`; `G§n` aponta para seções deste documento; `grupos.md §n` para a proposta.

- Decisões aplicadas (`grupos.md` §9 e §11, PLANO D11): **G1 = (c)**, **G2 = (a)**, **G4 = 100**,
  **D11** (mensagens seladas, conteúdo de grupo só em memória).
- Código de referência: `server/internal/proto/group*.go` (com testes em `group_test.go`).
- Vetores: `docs/vetores/grupos/`, gerados por `server/internal/testvec/gengrupos`.
- Regra de ouro igual à da v1: se o código diverge deste documento, o código está errado. Mudar o
  protocolo de grupos exige mudar este documento, o gerador e os vetores juntos.

"Deve" = obrigatório. "Recomendado" = a fase que implementa pode ajustar sem quebrar compatibilidade.

Este documento não edita nenhum arquivo existente. O que precisa mudar em `protocolo.md`,
`ameacas.md`, `PLANO.md`, `grupos.md` e no código está em G§14.

---

## 0. Resumo

| Peça | O que é | Seção |
|------|---------|-------|
| Cadeia de mudanças | Lista encadeada por hash de registros assinados (criar, adicionar, remover, promover, sair, renomear, encerrar). Só ela diz quem é membro. | G§2 |
| Chave do moderador | Ed25519 gerada offline. Assina os registros feitos pela CLI. Fixada no QR v=2 ou por QR de fixação. | G§3 |
| Época de grupo | A época da v1 com a posição da cadeia na declaração assinada. | G§5 |
| Metadados | Nome, descrição e foto cifrados com a chave da época, presos à cadeia por um compromisso. | G§6 |
| Mensagem selada | Forma que o servidor entrega no lugar da mensagem de autor inativo (D11). | G§7 |
| Revogação pré-assinada | Assinada no cadastro, guardada fora do cofre, enviada no "Esqueci a senha". | G§8 |
| `token reactivate` | Reabre o mesmo convite para recadastro. | G§9 |

## 1. Rótulos e limites novos

Todos seguem §2.1: ASCII seguido de `0x00`, nenhum é prefixo de outro, nem dos da v1.

| Rótulo | Uso | Seção |
|--------|-----|-------|
| `direct/v1/group-change` | registro da cadeia (assinado) | G§2.1 |
| `direct/v1/group-link` | hash do registro (`prev_hash` do seguinte) | G§2.3 |
| `direct/v1/group-epoch` | declaração de época de grupo (assinada) | G§5.1 |
| `direct/v1/group-meta-commit` | compromisso dos metadados (hash) | G§6.2 |
| `direct/v1/group-meta` | AAD dos metadados | G§6.3 |
| `direct/v1/sealed` | entrada do embaralhado da mensagem selada | G§7.2 |
| `direct/v1/self-revoke` | revogação pré-assinada | G§8.1 |
| `direct/v1/server-code-m` | código de verificação com a chave do moderador | G§3.3 |

| Limite | Valor |
|--------|-------|
| Membros por grupo (G4) | 100, em todo estado da cadeia |
| `change_bytes` | 131 a 4096 bytes |
| Aparelhos ativos por usuário | 4 (recomendado; hoje não há limite, ver G§14) |
| Corpo HTTP de `POST /v1/groups`, `POST /v1/groups/{id}/changes`, `POST /v1/conversations/{id}/epochs` e `POST /v1/groups/{id}/history-wraps` | 256 KiB (as demais rotas continuam com 64 KiB) |
| Metadados (JSON) | até 16383 bytes antes do preenchimento |

`conversation_id` de grupo é gerado por quem cria (app ou CLI), UUIDv4, porque entra no registro
assinado antes de o servidor ver o grupo. Conversa direta continua com id gerado pelo servidor.

## 2. Cadeia de mudanças assinada

### 2.1 Registro

```
change_bytes = "direct/v1/group-change\0"                                   # 23
            || conversation_id(16)
            || u64(n)                   # posição: 1 = criação, depois 2, 3, ...
            || prev_hash(32)            # 32 zeros em n = 1; senão G§2.3 do registro n-1
            || u32(kind)                # tabela G§2.2
            || u32(author_type)         # 1 = aparelho, 2 = moderador
            || author_device_id(16)     # zeros se moderador
            || author_user_id(16)       # zeros se moderador
            || u64(created_at)          # ms, relógio de quem assina; só informativo
            || u32(len(body)) || body                                       # 131 + len(body) bytes
signature    = Ed25519_sign(chave do autor, change_bytes)
```

- Chave do autor: `sign_seed` do aparelho (`author_type = 1`) ou semente do moderador (`= 2`, G§3).
- `created_at` não é conferido contra relógio nenhum nem exigido crescente: relógios erram. O app
  exibe o `received_at` do servidor (G§2.8) e mostra `created_at` só em "detalhes".
- **Codificação canônica:** um registro tem uma única codificação válida. Quem recebe decodifica,
  aplica as regras de G§2.2 (comprimento exato, listas em ordem crescente estrita de bytes, valores
  conhecidos) e recusa qualquer outra forma. O registro trafega como os bytes exatos
  (`change_bytes` em base64url), nunca como JSON reconstruído, então não há canonicalização de JSON.

### 2.2 Tipos e corpos

| `kind` | Nome | `body` | Tamanho |
|--------|------|--------|---------|
| 1 | criar | `u32(len(admin_label)) \|\| admin_label \|\| meta_commit(32) \|\| u32(m) \|\| m × (user_id(16) \|\| u32(role))` | 40 + len + 20m |
| 2 | adicionar | `u32(history) \|\| u32(k) \|\| k × user_id(16)` | 8 + 16k |
| 3 | remover | `u32(k) \|\| k × user_id(16)` | 4 + 16k |
| 4 | promover | `u32(k) \|\| k × user_id(16)` | 4 + 16k |
| 5 | sair | vazio | 0 |
| 6 | renomear | `meta_commit(32)` | 32 |
| 7 | encerrar | vazio | 0 |

- `role`: 1 = membro, 2 = admin. `history`: 0 = vê só a partir da entrada, 1 = histórico liberado (G2).
- Listas (`m` entradas de criar, `k` alvos): ordem crescente estrita por bytes do `user_id`, sem
  repetição; `m` e `k` de 1 a 101 (o 101 existe só para o erro sair como `limite`, G§2.6).
- `admin_label` (criar): 1 a 100 bytes com as regras de §2.3 **se** o autor é o moderador, e
  `meta_commit` = 32 zeros (o moderador não tem chave de época para cifrar nome). Se o autor é
  aparelho: `admin_label` vazio e `meta_commit` diferente de zeros (G§6).
- `meta_commit` (renomear): diferente de zeros.

### 2.3 Hash e registro inicial

```
record_hash = BLAKE2b-256( "direct/v1/group-link\0" || u32(len(change_bytes)) || change_bytes || signature )
```

- `prev_hash` do registro `n+1` = `record_hash` do registro `n`. O de `n = 1` é 32 zeros.
- O registro 1 é sempre `criar`, e `criar` só existe em `n = 1`.
- O hash inclui a assinatura: o registro gravado é exatamente aquele, com aquela assinatura.
- **Topo** da cadeia = `(n, record_hash)` do último registro.

### 2.4 Quem assina o quê

| `kind` | Admin do grupo (aparelho) | Membro comum (aparelho) | Moderador |
|--------|---------------------------|-------------------------|-----------|
| criar | sim: qualquer usuário cria (G1), e entra na lista como admin | — | sim, com `admin_label` |
| adicionar | sim | não | não |
| remover | sim, outros (inclusive admins); a si mesmo, não (usa sair) | não | sim, qualquer membro |
| promover | sim, membro comum para admin | não | não |
| sair | sim | sim | não |
| renomear | sim | não | não (não tem a chave da época) |
| encerrar | sim | não | sim |

Não há "rebaixar" na v1. O moderador não adiciona nem promove: se um grupo oficial fica sem
admin, o moderador encerra e cria outro. Isso limita o que uma chave do moderador roubada faz
(G§12).

"Admin" e "membro" são sempre conforme o estado **antes** do registro. O aparelho autor deve ter
certificado válido (§5.3) cujo `user_id` é `author_user_id`.

### 2.5 Estado

O estado depois do registro `n` é:

- `membros`: mapa `user_id → papel`. Criar define; adicionar inclui como membro; remover e sair
  tiram; promover muda o papel.
- `encerrado_em`: posição do registro `encerrar`, ou do registro que deixou o grupo sem nenhum
  membro. Depois dele nenhum registro é válido, nenhuma época é criada e nenhuma mensagem é aceita.
- `admin_label`, `meta_commit`: do criar; `meta_commit` muda com renomear.
- `intervalos`: por usuário, os períodos de participação `[de, até)` em posições da cadeia, cada um
  com o `history` do registro que o abriu. `de` = posição de criar ou adicionar; `até` = posição de
  remover ou sair (0 = ainda membro).

Duas consultas usam os intervalos:

- `membro_em(u, c)`: `u` era membro no estado logo depois do registro `c` (`de ≤ c < até`).
- `pode_reembrulhar(u, c)`: `u` é membro agora **e** (`membro_em(u, c)` **ou** algum intervalo de
  `u` tem `history = 1` e `c < de`). Decide quem pode receber, fora dos destinatários originais, a
  chave de uma época criada na posição `c` (G§5.4).

### 2.6 Algoritmo de verificação

O app (e o servidor, como defesa extra) começa do estado vazio e aplica os registros em ordem.
Para cada registro, **nesta ordem**, parando no primeiro erro:

| # | Confere | Código do erro |
|---|---------|----------------|
| 1 | `change_bytes` decodifica (G§2.1), `signature` tem 64 bytes, corpo canônico (G§2.2), incluindo as regras de `admin_label`/`meta_commit` por tipo de autor | `formato` |
| 2 | `conversation_id` é o do grupo | `conversa` |
| 3 | `n` = topo + 1, e `kind = criar` se e só se `n = 1` | `sequencia` |
| 4 | `prev_hash` = `record_hash` do topo (zeros em `n = 1`) | `prev_hash` |
| 5 | Autor: moderador com `author_device_id` e `author_user_id` zerados e chave do moderador fixada (G§3); ou aparelho com certificado conhecido, assinado pela `server_sign_pub` fixada, `cert.device_id = author_device_id` e `cert.user_id = author_user_id` | `autor` |
| 6 | `signature` confere com a chave do autor | `assinatura` |
| 7 | grupo não encerrado | `encerrado` |
| 8 | papel do autor (G§2.4); em criar, ao menos um admin, e o aparelho criador é admin na lista | `papel` |
| 9 | alvos: adicionar só quem não é membro; remover só membro e não a si mesmo; promover só membro comum | `alvo` |
| 10 | `len(membros) ≤ 100` depois de criar ou adicionar | `limite` |

Então aplica (G§2.5), e o topo passa a ser este registro.

Qualquer erro **recusa a cadeia inteira a partir daquele registro**: o hash encadeado impede pular
um registro ruim. O app mostra "a lista de membros deste grupo não confere", bloqueia envio e
criação de época no grupo e registra alerta local (sem conteúdo). Os certificados dos autores vêm
do diretório ou de `GET /v1/devices` (inclui revogados e vencidos, §7.2), porque um registro antigo
pode ter sido assinado por um aparelho que já saiu.

Referência: `GroupState.Apply` e `VerifyChain` em `server/internal/proto/group_chain.go`. Os
códigos são as constantes `Chain*` de `group.go`; os vetores `deve_falhar` de
`vetores/grupos/cadeia.json` trazem código e posição esperados.

### 2.7 Antes de embrulhar chave para alguém

Antes de criar época, liberar histórico ou enviar mensagem no grupo, o app:

1. Baixa a cadeia (`GET /v1/groups/{id}/changes`) e verifica do registro 1 até o topo (G§2.6).
2. **Âncora contra retrocesso:** o app guarda no banco cifrado só `(conversation_id, n, record_hash)`
   do maior topo já verificado (metadado, não conteúdo; D11 permite). A cadeia recebida deve ter
   pelo menos `n` registros e o registro `n` deve ter aquele hash. Se tiver menos ou o hash
   divergir: o servidor escondeu ou trocou registros; o app bloqueia o grupo e alerta.
3. Monta `S` = aparelhos ativos do diretório, com certificado verificado (§7.1), **só** dos usuários
   em `membros` da cadeia. A lista `members` que o servidor manda em `Conversation` é ignorada
   para confiança (resolve A2 para grupos).
4. Recusa se o grupo está encerrado.
5. Aplica a regra de época (G§5.3): os destinatários da época atual devem ser exatamente `S`.

Membro sem registro assinado válido nunca recebe chave.

### 2.8 Forma no fio

```json
{ "n": 3, "change_bytes": "<b64u>", "signature": "<b64u 64>", "received_at": 1798100120456 }
```

`received_at` é do servidor e não é assinado. O app monta o texto da linha do grupo a partir dos
bytes verificados ("Ana adicionou Marcos", com histórico ou sem) e da hora `received_at`.

## 3. Chave do moderador

### 3.1 Geração e arquivo

| Chave | Tipo | Onde nasce | Onde fica a privada | Quem confia na pública |
|-------|------|------------|---------------------|------------------------|
| Moderador `mod_sign` | Ed25519 | `direct-admin moderator init`, numa máquina offline | arquivo cifrado com senha, no pendrive, como o escrow | app, fixada pelo QR v=2 ou pelo QR de fixação |

- Arquivo: o mesmo formato de §13.1, com magia `direct-modkey-v1` (16 bytes ASCII, sem `0x00`) no
  lugar de `direct-escrow-v1`, e texto claro = a semente Ed25519 de 32 bytes. Total 112 bytes, mesmos
  limites de Argon2id ao ler.
- A privada nunca vai ao servidor. `moderator init --out <arquivo>` roda **offline**, imprime
  `mod_sign_pub` em base64url e o código de G§3.3. No servidor, `moderator register --pub <b64u>`
  grava só a pública em `server_keys.mod_pub`. Recusa se já existe (sem troca de chave na v1,
  como o escrow: trocar exige fixar de novo em todos os aparelhos).
- Recomendação de guarda igual à do escrow: senha com uma pessoa, pendrive com outra, duas cópias.
  Pode ser o mesmo pendrive do escrow, em arquivo separado e com senha diferente.
- `GET /v1/server-info` passa a devolver `"mod_pub": "<b64u 32>"` (ou `null` antes do registro).
  Não é assinado: o app só aceita esse valor pela comparação de G§3.4.

### 3.2 QR do convite, versão 2

```
direct://enroll?v=2&h=<host>&t=<invite_seed>&s=<server_sign_pub>&e=<escrow_pub>&m=<mod_sign_pub>
```

- Igual a §4.2, com `v=2` e o parâmetro obrigatório `m` (base64url de 32 bytes).
- `v=1` continua válido **sem** `m`; o aparelho cadastrado assim fica sem chave do moderador até
  G§3.4. `v=2` sem `m`, ou `v=1` com `m`, é recusado (são "parâmetro faltando" e "parâmetro
  desconhecido" de §4.2).
- A CLI escreve `v=2` sempre que `server_keys.mod_pub` existe.
- No cadastro, o app fixa `mod_sign_pub` junto com `server_sign_pub` e `escrow_pub` (§5.5, passo 3).

### 3.3 Código de verificação com a chave do moderador

```
dg = BLAKE2b-256( "direct/v1/server-code-m\0" || server_sign_pub || escrow_pub || mod_sign_pub )   # 120 bytes de entrada
```

Os 20 dígitos saem de `dg` como em §4.3. É diferente do código v1 (rótulo e entrada diferentes).
Na entrada manual de um convite v=2, o app calcula este código com as três chaves de
`GET /v1/server-info` e compara com o digitado.

### 3.4 Aparelhos já cadastrados

Um aparelho cadastrado com QR v=1 tem `server_sign_pub` e `escrow_pub` fixadas, mas nenhuma delas
autentica a chave do moderador: a do servidor está na mão de quem invadir o servidor. Por isso a
chave do moderador só é aceita por um canal fora do servidor:

1. **QR de fixação** (`direct-admin moderator qr`, impresso ou mostrado pessoalmente):

   ```
   direct://pin?v=1&h=<host>&s=<server_sign_pub>&e=<escrow_pub>&m=<mod_sign_pub>
   ```

   O app recusa se `h`, `s` ou `e` não forem **iguais** aos que já tem fixados (é de outro servidor)
   ou se faltar, repetir ou sobrar parâmetro (inclusive `t`). Aceito: fixa `m`.
2. **Código:** em Ajustes → "Ativar grupos", o app busca `mod_pub` em `GET /v1/server-info`, calcula
   o código de G§3.3 com as chaves **fixadas** `s` e `e` e o `m` recebido, e pede que o usuário
   confira com o código que o moderador distribuiu (papel, mural, pessoalmente). O usuário digita o
   código; igual = fixa `m`; diferente = aviso de servidor não confiável, nada é fixado.

Enquanto `m` não está fixado, o app **não mostra nem verifica grupos**: sem a chave, um registro
"do moderador" não pode ser conferido, e aceitar a chave do servidor deixaria o invasor forjar
membros. Conversas 1:1 não mudam.

### 3.5 Registros assinados pela CLI

`group create`, `group remove-member` e `group close` (G§10.4) rodam no notebook do moderador,
falando com o banco por túnel SSH (como o `rewrap`, PLANO 5.2). A CLI:

1. Lê o arquivo com `--mod-key`, pede a senha, confere `pub(semente) = server_keys.mod_pub`.
2. Lê a cadeia do grupo e a verifica (G§2.6); não assina em cima de cadeia inválida.
3. Monta o registro com `n = topo + 1`, `prev_hash = hash do topo`, assina, grava na mesma transação
   que trava o grupo (`SELECT ... FOR UPDATE`). Se o topo mudou, refaz.
4. Zera a semente da memória.

## 4. Papéis e decisões

- **G1 = (c).** Qualquer usuário cria grupo comum pelo app (registro criar assinado pelo aparelho,
  sem rótulo em claro). O moderador cria grupos oficiais pela CLI (assinado pela chave do
  moderador, com `admin_label` e ao menos um admin) e pode remover membro e encerrar qualquer grupo.
- **G2 = (a), com liberação.** Quem entra recebe só as épocas criadas a partir da sua entrada
  (`membro_em`). O admin que adiciona pode marcar `history = 1`; aí o app dele reembrulha as épocas
  antigas que tem para os aparelhos do novo membro (G§5.4). A liberação fica gravada na cadeia e
  aparece para todos: "Ana adicionou Marcos com acesso ao histórico".
- **G4 = 100.** Verificado em todo registro (G§2.6, passo 10). O servidor recusa antes; o app
  recusa mesmo que o servidor aceite.

## 5. Épocas de grupo

### 5.1 Declaração

Num grupo, a declaração de §9.3 é substituída por:

```
group_epoch_bytes = "direct/v1/group-epoch\0" || conversation_id(16) || u32(epoch) || creator_device_id(16)
                 || key_commitment(32) || escrow_pub(32)
                 || u64(chain_n) || chain_hash(32)                       # topo da cadeia usado para montar recipients
                 || u32(n) || recipients[0](16) || ... || recipients[n-1](16)          # 166 + 16n bytes
epoch_sig         = Ed25519_sign(sign_seed do criador, group_epoch_bytes)
```

`K`, compromisso (§9.2), embrulhos (§9.4) e `recipients` (ordem crescente, sem repetição) iguais à
v1. A posição da cadeia prende a época ao estado de membros que o criador verificou: quem recebe
consegue conferir que nenhum destinatário estava fora do grupo naquele momento.

### 5.2 Validação no app (acrescenta a §9.8)

Para um `EpochItem` de grupo, além de §9.8 com `group_epoch_bytes`:

1. `chain_n` existe na cadeia verificada e o registro `chain_n` tem hash `chain_hash`; o grupo não
   estava encerrado em `chain_n`. Senão `cadeia`.
2. O dono do criador (certificado verificado) é `membro_em(dono, chain_n)`. Senão `papel`.
3. Se o próprio aparelho está em `recipients`: o dono de **cada** destinatário é
   `membro_em(dono, chain_n)`. Senão `alvo`. Destinatário de fora do grupo = alguém embrulhou para
   um fantasma; o app descarta a época e alerta.
4. Se o próprio aparelho **não** está em `recipients` (liberação de histórico ou `rewrap`):
   `pode_reembrulhar(próprio usuário, chain_n)`. Senão descarta.
5. `chain_n` não diminui de uma época para a seguinte.

Referência: `GroupState.CheckGroupEpoch` (passos 1 a 3) e `MayRewrap` (passo 4).

### 5.3 Quem cria e quando

Regra geral igual a §9.5, com `S` vindo da cadeia (G§2.7). Os casos:

| Evento | Quem cria a época | Quando |
|--------|-------------------|--------|
| Criar (pelo app) | o criador | no mesmo `POST /v1/groups`, época 1 com `chain_n = 1` |
| Criar (pelo moderador) | o primeiro membro que enviar | quando enviar (§9.5, caso `L = 0`) |
| Adicionar | o admin que adiciona | no mesmo pedido do registro, incluindo os aparelhos do novo membro |
| Remover (admin) | o admin que remove | no mesmo pedido do registro, sem os aparelhos do removido. Quem saiu não lê a próxima mensagem de ninguém |
| Remover (moderador) | o próximo remetente | o servidor passa a responder `epoch_required` (os `recipients` da época atual não batem com os membros) |
| Sair | o próximo remetente | idem. Quem sai não deve criar a época que o exclui: ele conhece a chave atual de qualquer jeito |
| Aparelho entra, sai, é revogado ou vence | o próximo remetente | como no 1:1 |
| Promover, renomear, encerrar | ninguém | não muda destinatários |

"No mesmo pedido" = registro e época numa só requisição e numa só transação no servidor
(G§10.1). Se um dos dois falha, nenhum é gravado.

### 5.4 Liberação de histórico (G2) e reembrulho (S1)

- **Pelo admin.** Depois de um `adicionar` com `history = 1` na posição `a`, o app do admin
  reembrulha cada época que tem, criada em `chain_n < a`, para cada aparelho ativo de cada usuário
  adicionado: `crypto_box_seal(K, kex_pub)` com o `kex_pub` do certificado verificado. Envia em
  `POST /v1/groups/{id}/history-wraps` (G§10.1). Libera só o que o próprio app tem: se o admin
  entrou sem histórico, não tem as épocas anteriores a ele. O escrow completa (abaixo).
- **Pelo servidor.** Aceita um item só se: o registro `add_n` é `adicionar` com `history = 1`; o
  dono do aparelho está entre os alvos dele e segue membro; a época existe e tem `chain_n < add_n`;
  ainda não há embrulho daquela época para aquele aparelho.
- **Pelo app que recebe.** Valida como G§5.2, passo 4 (`pode_reembrulhar`), mais o compromisso.
- **Pelo escrow (`direct-admin escrow rewrap`, §13.3).** A correção de S1 vale também para grupos:
  para cada época de grupo, a CLI verifica a cadeia do grupo (com a chave do moderador e a do
  servidor) e reembrulha para o aparelho do usuário **só** se `pode_reembrulhar(usuário, chain_n)`.
  Épocas de grupos de que ele nunca participou, ou de antes da entrada sem histórico liberado, ficam
  de fora. A CLI lista, por grupo, o registro que autoriza (por exemplo "entrou em 12/11, adicionado
  por Ana, sem histórico: épocas 7 a 12") e pede confirmação, junto com a conferência de impressão
  digital do aparelho que S1 já exige.

A regra é a mesma nos três lugares: **só se reembrulha o que a cadeia assinada permite.**

### 5.5 Custo para 100 membros

Conta com `D` = aparelhos ativos de todos os membros. Típico: 100 membros × 2 aparelhos = 200.
Máximo com o limite recomendado: 100 × 4 = 400.

| Item | Fórmula | D = 200 | D = 400 |
|------|---------|---------|---------|
| Embrulhos por época (sealed box de 80 bytes, + escrow) | 80 × (D + 1) | 16,1 KB | 32,1 KB |
| Declaração assinada | 166 + 16D | 3,4 KB | 6,6 KB |
| Corpo JSON do `POST` da época (`recipients` ≈ 39 B, `wraps` ≈ 177 B por aparelho, mais metadados até ≈ 22 KB) | ≈ 216D + 22 KB | ≈ 65 KB | ≈ 108 KB |
| `EpochItem` que cada aparelho baixa (lista de destinatários + seu embrulho) | ≈ 39D + 0,5 KB | ≈ 8 KB | ≈ 16 KB |
| Saída total do servidor no evento `epoch` | D × item | ≈ 1,7 MB | ≈ 6,4 MB |
| Selagens no aparelho criador (2 X25519 cada) | D + 1 | 201 (dezenas de ms num celular médio) | 401 |
| Linhas em `epoch_key_wraps` | D + 1 | 201 | 401 |

Consequências:
- O corpo passa de 64 KiB: as rotas de época e grupo aceitam até 256 KiB (G§1).
- O quadro WebSocket `epoch` (≈ 16 KB no pior caso) cabe nos 64 KiB.
- `GET /v1/epochs/mine` com `limit = 500` itens de grupo daria ≈ 4 a 8 MB: recomendado o servidor
  reduzir o lote para a resposta ficar abaixo de 2 MiB (`has_more` resolve o resto).
- Frequência: uma época por entrada, remoção, saída ou troca de aparelho de qualquer membro. Com
  200 aparelhos vencendo a cada 180 dias, só os vencimentos já dão perto de uma época por dia.
  Aceitável. Acima de algumas centenas de aparelhos, MLS (RFC 9420), fora do escopo (`grupos.md` §4).
- Verificar a cadeia: um Ed25519 por registro e um por certificado de autor distinto. Centenas de
  registros custam poucos milissegundos.

## 6. Nome, foto e descrição cifrados

### 6.1 Texto claro

```json
{"v":1,"salt":"<b64u 32>","name":"Projeto Atlas","description":"Equipe do projeto Atlas","photo":"<b64u JPEG>"}
```

| Campo | Regra |
|-------|-------|
| `v` | `1` |
| `salt` | 32 bytes aleatórios novos a cada mudança. Impede o servidor de adivinhar o nome pelo compromisso |
| `name` | 1 a 64 code points, sem caracteres de controle |
| `description` | 0 a 500 code points, sem caracteres de controle |
| `photo` | opcional; JPEG gerado dos pixels (sem metadados, como §18.3), lado maior até 256 px, até 8192 bytes |

Campos desconhecidos: ignorados. Fora da regra: o app mostra o nome provisório (abaixo).
A foto vai dentro dos metadados, não em blob: assim não fica sujeita ao bloqueio de G§7.5 e não
some se o admin que a pôs perder o acesso.

### 6.2 Compromisso

```
meta_commit = BLAKE2b-256( "direct/v1/group-meta-commit\0" || conversation_id(16) || u32(len(meta)) || meta )
```

`meta` = os bytes exatos do JSON. Quem recifra (G§6.4) copia esses bytes, sem reserializar.
`meta_commit` vai no registro criar (grupo do app) ou renomear, então é assinado por um admin.

### 6.3 Cifra

```
aad        = "direct/v1/group-meta\0" || conversation_id(16) || u32(epoch) || meta_commit(32)       # 73 bytes
nonce      = 24 bytes aleatórios
ciphertext = XChaCha20-Poly1305-IETF-Encrypt(K da época, nonce, sodium_pad(meta, 256), aad)
```

Forma no fio (`GroupMeta`):

```json
{ "epoch": 2, "meta_commit": "<b64u 32>", "nonce": "<b64u 24>", "ciphertext": "<b64u>" }
```

O app abre com a `K` da época, tira o preenchimento, recalcula `meta_commit` e compara em tempo
constante com o `meta_commit` **do estado atual da cadeia**. Diferente = descarta.
Referência: `MetaCommit`, `MetaAAD`, `SealMeta`, `OpenMeta` em `group_meta.go`.

### 6.4 Validade entre épocas

Quem entra sem histórico não tem as épocas antigas e não abriria um nome cifrado lá. Por isso:

- Renomear: o admin envia o registro e o `GroupMeta` cifrado com a época atual, no mesmo pedido.
- Toda época nova de grupo com `meta_commit` não nulo vem com o `GroupMeta` atual recifrado com a
  `K` nova, pelo criador da época. O servidor recusa época de grupo sem ele (400 `bad_request`).
- Quem recifra não consegue trocar o nome: o compromisso é do admin, e o recifrado só vale se bater.

### 6.5 Rótulo administrativo e nome provisório

- Grupo do moderador: `admin_label` em claro no registro criar, assinado pela chave do moderador.
  O moderador o vê na CLI; os membros também, como subtítulo ("oficial: Diretoria - oficial").
  Enquanto nenhum admin renomear, o app mostra o `admin_label` como nome.
- Grupo comum: sem rótulo em claro. O servidor e o Cloudflare não sabem o nome. A CLI mostra id,
  membros, admins e datas.
- Sem metadados válidos (ainda não chegou a época, ou não conferem): o app mostra "Grupo" seguido
  dos 3 primeiros `admin_label` dos membros.

## 7. Mensagens seladas (D11)

### 7.1 Membro ativo

Um usuário é **ativo** quando `users.disabled_at IS NULL` **e** ele tem ao menos um aparelho ativo
(§3: `revoked_at IS NULL` e `expires_at > agora`). Estar offline não muda nada.
Num grupo, a mensagem de um membro só sai legível se o autor (dono de `sender_device_id`) está
ativo **agora**, não quando enviou. Vale para membros e ex-membros: quem saiu do grupo e segue
ativo continua com as mensagens antigas legíveis. No 1:1 não há selagem.

O servidor registra cada transição em `user_access_events` (G§10.2). Transições:

| Para inativo | Para ativo |
|--------------|------------|
| `device revoke` ou `self-revoke` do último aparelho ativo; `user disable`; vencimento do último aparelho (o servidor varre `expires_at` a cada minuto) | cadastro de aparelho (`/v1/enroll`) de usuário que estava sem nenhum ativo |

### 7.2 Formato da mensagem selada

No lugar de `Message` (§10.5), em `GET /v1/conversations/{id}/messages` e em qualquer reenvio
pelo WebSocket, o servidor entrega:

```json
{ "conversation_id": "uuid", "seq": 7, "message_id": "uuid",
  "sender_device_id": "uuid", "sender_user_id": "uuid", "created_at": 1798100600000,
  "sealed": true, "scramble": "v*SgAeg9dNL8" }
```

- **Não vão** `epoch`, `nonce`, `ciphertext`, `signature` nem `sent_at`. O texto cifrado real
  não sai do servidor.
- `scramble` (embaralhado, só para exibir):

  ```
  h      = BLAKE2b-256( "direct/v1/sealed\0" || conversation_id(16) || u64(seq) )        # 41 bytes de entrada
  blocos = (len(ciphertext) - 16) / 256                                                   # 1 a 64
  L      = 12 + 4 × min(max(blocos - 1, 0), 5)                                            # 12, 16, ... 32
  scramble[i] = ALFABETO[h[i] & 63], i = 0 .. L-1
  ALFABETO = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRST#@%&$*!?"           # 64 caracteres
  ```

  Depende só de conversa, `seq` e faixa de tamanho, nunca do conteúdo: não serve para decifrar
  nada, e o tamanho em blocos o servidor já conhece. É estável entre buscas.
- O app mostra `scramble` em fonte de texto comum, sem permitir copiar, com o nome do autor
  (`admin_label` do certificado de `sender_device_id`). Referência: `NewSealed`, `Scramble`.

### 7.3 Evento `member_access`

```json
{ "type": "member_access", "user_id": "uuid", "active": false, "at": 1798100700000,
  "conversations": ["uuid"] }
```

- Enviado a cada conexão cujo escopo (§11.3) contém algum grupo em que `user_id` é ou foi membro e
  tem mensagem. `conversations` lista só os grupos do escopo daquela conexão.
- `active = false`: o app apaga da memória texto cifrado, texto claro e imagens das mensagens desse
  autor nesses grupos, troca por seladas (buscando de novo o histórico, que agora vem selado, ou
  gerando o embaralhado pela mesma fórmula) e insere a linha "perdeu o acesso".
- `active = true`: o app busca de novo o histórico desses grupos e insere "voltou ao grupo".

### 7.4 Linhas "perdeu o acesso" e "voltou ao grupo"

`GET /v1/conversations/{id}/access-events?after=<id>` (só grupos, só membros):

```json
{ "events": [ { "id": 41, "user_id": "uuid", "active": false, "at": 1798100700000 } ], "has_more": false }
```

Só eventos de usuários que eram membros (pela tabela de membros do servidor) no instante `at`. O
app intercala as linhas por `at` com o `created_at` das mensagens:

```
— Marcos Lima - TI perdeu o acesso —
— Marcos Lima - TI voltou ao grupo —
```

São diferentes de sair e entrar: a pessoa continua membro e a cadeia não muda. Os eventos não são
assinados: quem decide se alguém está ativo é o servidor (G§12).

### 7.5 Imagens e salvamentos

- `GET /v1/blobs/{id}`: se a conversa do blob é grupo e o dono do `uploader_device_id` está
  inativo, 403 `{"error": {"code": "sender_inactive", ...}}`. A miniatura vira cadeado.
- `POST /v1/media/saves` para mensagem de grupo cujo autor está inativo: 403 `sender_inactive`.

### 7.6 Regras do cliente

- **Grupo só em memória.** Chaves de época de grupo, texto cifrado, texto aberto, imagens,
  metadados e a cadeia de grupo não vão para disco (nem SQLCipher, nem cache HTTP, nem arquivo
  temporário). Ficam em memória enquanto o app está destravado. Trancar, fechar a bolha do grupo,
  ir para o fundo além do tempo de trava, fechar o app ou o processo morrer apaga tudo. No disco
  ficam só: a âncora `(conversation_id, n, record_hash)` (G§2.7), a chave do moderador fixada e o
  cursor de 1:1.
- **Chaves de grupo vêm de novo a cada sessão.** O cursor `wrap_id` de `GET /v1/epochs/mine` é do
  1:1: o app pula itens de grupo ao gravar e busca as épocas de um grupo ao abri-lo, por
  `GET /v1/conversations/{id}/epochs/mine` (G§10.1).
- **Abrir um grupo:** verificar a cadeia; buscar épocas e metadados; buscar as últimas 200
  mensagens (`before`, G§10.1) e o resto ao rolar; buscar `access-events`.
- **Sem internet, só 1:1.** A lista mostra as conversas 1:1 pela cópia local e um item "Grupos
  indisponíveis sem conexão". Os grupos aparecem depois de login e `ready`.
- Chat flutuante (D7) de grupo: o mesmo, com escopo daquele grupo. Fechar a bolha apaga da memória.

## 8. Revogação pré-assinada

### 8.1 Formato

```
self_revoke_bytes = "direct/v1/self-revoke\0" || server_sign_pub(32) || device_id(16) || u64(created_at)   # 78 bytes
sig               = Ed25519_sign(sign_seed do aparelho, self_revoke_bytes)
```

`created_at` = relógio do aparelho ao assinar, em ms. É informativo (registro de auditoria) e não
é comparado com nada: a revogação pode ter meses quando for usada, e o relógio do aparelho pode
estar errado. `server_sign_pub` prende a revogação a este servidor.

Forma guardada e enviada:

```json
{ "device_id": "uuid", "created_at": 1798200000000, "sig": "<b64u 64>" }
```

### 8.2 Onde fica

**Fora do cofre**, legível sem senha, só neste aparelho e sem backup:

- Android: arquivo privado do app cifrado com chave AES do Android Keystore criada **sem**
  `setUserAuthenticationRequired`; fora do backup automático (`dataExtractionRules` e
  `fullBackupContent` excluindo o arquivo; ver A5).
- iOS: item do Keychain com `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, sem sincronizar.

É apagada junto com todo o resto (§12 e "Esqueci a senha").

**Quando gera:** no cadastro, logo depois de validar o certificado (§5.5, passo 3). Aparelhos já
cadastrados geram no próximo desbloqueio com senha ou digital, quando o cofre abre e a semente
está disponível, se ainda não tiverem.

### 8.3 `POST /v1/devices/self-revoke`

Sem token de acesso (quem esqueceu a senha não consegue fazer login). Corpo = a forma de G§8.1.

O servidor, na ordem:
1. Formato (UUID, base64url, 64 bytes). Erro: 400 `bad_request`.
2. Busca o aparelho por `device_id` e verifica `sig` com o `sign_pub` dele sobre
   `self_revoke_bytes` montado com a própria `server_sign_pub`. Aparelho inexistente ou assinatura
   inválida: 401 `auth_failed`, sempre a mesma resposta.
3. Aparelho já revogado: 200 com o `revoked_at` original, sem mudar nada.
4. Senão faz o mesmo que `device revoke` (§12) numa transação, com `revoked_reason = 'self'`, e
   grava `created_at` da requisição no registro de auditoria. Se era o último aparelho ativo do
   usuário, grava a transição em `user_access_events` e envia `member_access` (G§7.3).
5. 200 `{"revoked_at": ms}`.

Limite de taxa recomendado: 5 por minuto por IP. Referência: `SelfRevokeBytes`, `VerifySelfRevoke`.

O app, no "Esqueci a senha" (PLANO 6.5): com internet, envia e espera até 10 s pela resposta
(qualquer resposta ou erro de rede); depois apaga tudo de qualquer jeito. Sem internet, apaga sem
enviar; o moderador revoga pela CLI.

### 8.4 Repetição

Reenviar a mesma revogação não tem efeito, e é por isso que ela pode viver sem senha:

- O `device_id` está assinado: não serve para outro aparelho. `server_sign_pub` está assinada: não
  serve para outro servidor.
- `device_id` nunca é reaproveitado: cada cadastro (inclusive com `token reactivate`) cria aparelho
  novo com id novo. A revogação é final na v1: não existe "desrevogar".
- Repetir sobre aparelho já revogado cai no passo 3 (nada muda).
- Se um dia existir restauração de aparelho revogado, ela deve invalidar as revogações
  pré-assinadas antigas (por exemplo, coluna `self_revoke_not_before` comparada com `created_at`).

Risco aceito (`grupos.md` §11.3): quem pega o celular desbloqueado consegue revogar aquele aparelho.
Só derruba o acesso; não lê nada.

## 9. `direct-admin token reactivate <id> --ttl 24h`

Reabre **o mesmo** convite para recadastro (D11, `grupos.md` §11.2):

1. O token deve existir, não estar revogado (`token revoke`) e ter sido usado ou vencido. O usuário
   dele não pode estar desativado.
2. `--ttl` obrigatório, de 1 minuto a 7 dias (teto de S10).
3. Numa transação: `used_at = NULL`, `used_by_device = NULL`, `expires_at = agora + ttl`,
   `reactivated_at = agora`, `reactivations = reactivations + 1`. Se o token era `--new-user`, passa
   a apontar para o usuário criado no primeiro uso (`user_id` preenchido): reativar nunca cria
   usuário novo.
4. Continua de uso único: o próximo `/v1/enroll` com ele marca `used_at` de novo (§5.4).
5. Registro de auditoria (quem, quando, token, ttl).

O servidor não guarda a semente do convite (§4.1), então a CLI **não consegue reimprimir o QR**:
`reactivate` só serve se a pessoa ainda tem o QR original (papel, foto guardada). A CLI avisa disso.
Se o QR se perdeu, ou pode ter sido visto por outra pessoa, use `token create --user <id>`.

## 10. Servidor (G-B)

### 10.1 Rotas

| Método | Rota | Função |
|--------|------|--------|
| GET | `/v1/server-info` | acrescenta `mod_pub` (G§3.1) |
| POST | `/v1/groups` | cria grupo pelo app: registro 1 + época 1 + `GroupMeta` |
| POST | `/v1/groups/{id}/changes` | acrescenta registro (com época ou metadados quando G§5.3/G§6.4 exigem) |
| GET | `/v1/groups/{id}/changes?after={n}&limit={k}` | cadeia, ordem crescente de `n`; `limit` padrão e máximo 500 |
| GET | `/v1/groups/{id}/meta` | `{"items": [GroupMeta]}` com o `meta_commit` atual, até 20, época decrescente |
| POST | `/v1/groups/{id}/history-wraps` | liberação de histórico pelo admin (G§5.4) |
| GET | `/v1/conversations/{id}/epochs/mine` | todos os `EpochItem` deste aparelho naquela conversa (para grupos, G§7.6) |
| GET | `/v1/conversations/{id}/messages?after=&before=&limit=` | `before` novo (busca para trás); seladas para autor inativo (G§7.2) |
| GET | `/v1/conversations/{id}/access-events?after=` | linhas de acesso (G§7.4) |
| POST | `/v1/conversations/{id}/epochs` | em grupo: corpo com `chain_n`, `chain_hash`, `meta` (G§10.3) |
| POST | `/v1/devices/self-revoke` | sem token (G§8.3) |
| GET | `/v1/blobs/{id}`, POST `/v1/media/saves` | 403 `sender_inactive` (G§7.5) |

`POST /v1/groups`:

```json
{
  "change": { "change_bytes": "<b64u>", "signature": "<b64u 64>" },
  "epoch":  { "epoch": 1, "creator_device_id": "uuid", "key_commitment": "<b64u 32>",
              "chain_n": 1, "chain_hash": "<b64u 32>",
              "recipients": ["uuid"], "wraps": [{"device_id": "uuid", "wrapped_key": "<b64u 80>"}],
              "escrow_wrap": "<b64u 80>", "signature": "<b64u 64>" },
  "meta":   { "epoch": 1, "meta_commit": "<b64u 32>", "nonce": "<b64u 24>", "ciphertext": "<b64u>" }
}
```

O servidor, numa transação:
1. Registro: `n = 1`, `kind = criar`, autor = aparelho autenticado. `conversation_id` livre (senão
   409 `group_exists`). Todos os `user_id` da lista existem e não estão desativados (senão 400
   `bad_request`).
2. Verifica com `Apply` (G§2.6) usando os certificados e `mod_pub` do banco. Falha: 400
   `chain_invalid` com `"reason": "<código>"`.
3. Época como §9.6, com `group_epoch_bytes`, `chain_n = 1`, `chain_hash` = hash do registro 1 e
   `recipients` = aparelhos ativos dos membros. `meta.meta_commit` = o do registro, `meta.epoch = 1`.
4. Grava conversa (`kind = 'group'`), registro, membros com papel, época, embrulhos, metadados.
5. 201 `Conversation`. Eventos: `conversation` aos membros, `epoch` aos destinatários.

`POST /v1/groups/{id}/changes`: `{"change": {...}, "epoch": {...}|null, "meta": {...}|null}`.
1. Autenticado; o autor do registro é o aparelho autenticado; o usuário é membro. Senão 403.
2. Trava o grupo. `n ≠ topo + 1`: 409 `chain_conflict` com `"chain_n": topo`. Encerrado: 409
   `group_closed`.
3. `Apply`; falha: 400 `chain_invalid` com `reason`.
4. Acompanhantes: adicionar e remover exigem `epoch` (`chain_n` = este `n`, `recipients` = aparelhos
   ativos dos membros **depois** do registro, metadados recifrados se houver); renomear exige `meta`
   com a época atual e o `meta_commit` do registro; os demais recusam `epoch` e `meta`. Errado:
   400 `bad_request`.
5. Grava tudo, atualiza `conversation_members` (entrada, saída, papel) e `conversations`
   (`chain_n`, `chain_hash`, `closed_at`).
6. 201 `{"n": n}`. Eventos: `group_change` a todas as conexões de quem era membro antes **ou** é
   depois (o removido fica sabendo); `epoch`; `conversation` aos adicionados.

Registros do moderador não passam por HTTP: a CLI grava direto no banco (G§3.5) e chama
`NOTIFY group_change` para o `directd` enviar os eventos.

### 10.2 Tabelas (migração nova)

```
server_keys          + mod_pub bytea NULL CHECK (length = 32)
conversations        + admin_label text NULL, chain_n bigint NOT NULL DEFAULT 0,
                       chain_hash bytea NULL, closed_at timestamptz NULL
conversation_members + role text NOT NULL DEFAULT 'member' CHECK (role IN ('member','admin')),
                       joined_n bigint NULL, left_n bigint NULL, history boolean NOT NULL DEFAULT false
                       (uma linha por intervalo: PK passa a (conversation_id, user_id, joined_n) para grupos)
group_changes(conversation_id uuid, n bigint, change_bytes bytea, signature bytea, record_hash bytea,
              kind smallint, author_device_id uuid NULL, author_user_id uuid NULL,
              received_at timestamptz, PRIMARY KEY (conversation_id, n))
epochs               + chain_n bigint NULL, chain_hash bytea NULL   (NULL = conversa direta)
epoch_key_wraps      + source text NOT NULL DEFAULT 'creator' CHECK (source IN ('creator','history','escrow'))
group_meta(conversation_id uuid, epoch integer, meta_commit bytea, nonce bytea, ciphertext bytea,
           PRIMARY KEY (conversation_id, epoch))
user_access_events(id bigserial PRIMARY KEY, user_id uuid, active boolean, at timestamptz)
devices              + revoked_reason text NULL CHECK (revoked_reason IN ('admin','self','user_disabled','expired'))
enrollment_tokens    + revoked_at timestamptz NULL, reactivated_at timestamptz NULL,
                       reactivations integer NOT NULL DEFAULT 0
blobs                (sem mudança: o autor vem de uploader_device_id)
```

### 10.3 Época de grupo em `POST /v1/conversations/{id}/epochs`

Corpo de §9.6 mais `chain_n`, `chain_hash` e `meta` (obrigatório se o `meta_commit` atual não é
zero). O servidor monta `group_epoch_bytes` e confere: `chain_n` e `chain_hash` = topo atual (senão
409 `chain_conflict`), grupo aberto (senão 409 `group_closed`), `recipients` = aparelhos ativos dos
membros (senão 409 `device_set_changed`), `meta.meta_commit` = atual e `meta.epoch` = a época nova.
O `EpochItem` de grupo ganha `chain_n` e `chain_hash`.

Mensagem (`send`) em grupo encerrado: `error` com `group_closed`.

### 10.4 CLI

```
direct-admin moderator init --out /mnt/pendrive/moderador.key     # offline; imprime mod_pub e código
direct-admin moderator register --pub <b64u>                      # no servidor; só a pública
direct-admin moderator qr                                         # QR de fixação e código (G§3.4)
direct-admin group list
direct-admin group show <id>                                      # id, rótulo, membros, admins, cadeia (sem nome)
direct-admin group create --label "<rótulo>" --admin <user_id>... [--member <user_id>...] --mod-key <arquivo>
direct-admin group remove-member <id> <user_id> --mod-key <arquivo>
direct-admin group close <id> --mod-key <arquivo>
direct-admin token reactivate <id> --ttl 24h                      # G§9
```

`group show` imprime cada registro verificado ("3 · promover · João por Ana (aparelho …) ·
25/11 14:02") e avisa se a cadeia não confere.

### 10.5 Eventos

| `type` | Campos | Quando |
|--------|--------|--------|
| `group_change` | `conversation_id`, `change` (G§2.8), `meta` (`GroupMeta` ou `null`) | registro novo; vai a membros de antes e de depois |
| `member_access` | G§7.3 | transição de acesso de um usuário |
| `conversation` | `Conversation` com `kind: "group"` | grupo criado ou usuário adicionado |
| `epoch` | `EpochItem` com `chain_n`, `chain_hash` | como na v1 |

`Conversation` de grupo: `{"conversation_id", "kind": "group", "members": [...], "latest_epoch",
"last_seq", "chain_n", "admin_label": "..."|null, "closed": false}`. `members` é informativo.

### 10.6 Códigos de erro novos

| Código | HTTP | Onde |
|--------|------|------|
| `chain_invalid` | 400 | registro não passa em G§2.6; `reason` = código da tabela |
| `chain_conflict` | 409 | `n` ou `chain_n` diferente do topo; corpo traz `chain_n` atual |
| `group_closed` | 409 / WebSocket | grupo encerrado |
| `group_exists` | 409 | `conversation_id` de grupo já usado |
| `sender_inactive` | 403 | blob ou salvamento de autor inativo |

## 11. App (G-C)

1. **Fixar a chave do moderador:** QR v=2 no cadastro; QR de fixação ou código em Ajustes para
   aparelhos antigos (G§3.4). Sem ela, a aba de grupos mostra "Ative os grupos" e nada mais.
2. **Criar grupo:** escolher pessoas no diretório (até 99 além de si) e o nome. Gerar
   `conversation_id`, `salt`, metadados, registro criar, época 1 com `chain_n = 1`; `POST /v1/groups`.
3. **Tela de informações:** membros com papel; a cadeia como histórico legível; adicionar (com a
   opção "mostrar o histórico para quem entra", desmarcada por padrão), remover, promover,
   renomear, encerrar (só admin); sair (todos).
4. **Antes de qualquer envio:** G§2.7 e G§5.3. Erro 409 de cadeia ou época: baixar de novo e tentar
   até 3 vezes.
5. **Mensagens:** nome do remetente (`admin_label`) em cada mensagem; verificação de §10.7 com o
   passo 3 trocado por "o dono do remetente é `membro_em(dono, chain_n da época)`".
6. **Seladas e linhas de acesso:** G§7.2 a G§7.4. Mensagem selada não tem menu de copiar, responder
   nem salvar.
7. **Só em memória e sem internet só 1:1:** G§7.6.
8. **Revogação pré-assinada:** gerar no cadastro e no primeiro desbloqueio de aparelho antigo;
   enviar no "Esqueci a senha" (G§8).
9. **Aviso de aparelho novo (A1) também em grupos:** ao ver `sign_pub` novo de um membro, linha no
   grupo "<nome> conectou um aparelho novo". Para admins, destacar: um aparelho de admin pode
   assinar registros (G§12).
10. **Alertas:** cadeia inválida, âncora divergente, época com destinatário de fora, metadados que
    não conferem. Bloqueiam o grupo, sem mostrar conteúdo.

## 12. Ameaças novas

Complementa `ameacas.md`. "Invasor do servidor" tem a chave de assinatura do servidor e o banco.

| Ameaça | O que impede | O que sobra |
|--------|--------------|-------------|
| **Servidor forja membro** (inclui alguém na lista para receber chave) | A lista confiável é a cadeia (G§2.7); registro novo exige assinatura de admin do grupo ou do moderador, que o servidor não tem. Destinatário fora da cadeia faz quem recebe descartar a época (G§5.2) | O caminho do aparelho fantasma, abaixo |
| **Aparelho fantasma em grupo (A1)** | Fantasma de **membro comum**: entra na próxima época como no 1:1, porque o app confia em certificado assinado pelo servidor. Defesa: aviso de aparelho novo (A1) em todos os grupos do usuário. Fantasma de **admin**: além disso, pode assinar registros como o admin (adicionar um usuário falso, liberar histórico). Defesa: cada registro vira linha visível para todos ("Ana adicionou X com histórico, pelo aparelho novo de Ana"); o app destaca registros feitos por aparelho que surgiu há menos de 7 dias | Quem ignora os avisos. Sem A1 implementado, esta é a principal brecha dos grupos: G-C só deve liberar grupos com A1 pronto |
| **Servidor esconde ou volta a cadeia** (esconde uma remoção para o removido continuar recebendo) | Âncora local `(n, hash)` (G§2.7); o servidor não consegue ramificar a cadeia sem assinaturas | Aparelho que nunca viu o registro novo (instalação nova, primeira abertura) aceita o prefixo que o servidor mostrar. Atraso: o registro aparece quando o servidor parar de esconder |
| **Servidor sela mensagens** de quem está ativo | — (D11 dá essa decisão ao servidor) | Negação de serviço do histórico daquela pessoa. Não lê nada |
| **Servidor libera mensagens** de quem perdeu o acesso | A chave da época continua só com aparelhos de membros e com o escrow | Membros veem o que já podiam ver antes. Não é vazamento para fora do grupo |
| **Servidor forja linhas de acesso** ("perdeu o acesso" falso) | — | Confusão na conversa; nada é lido |
| **Rewrap de épocas de grupo (S1)** | App do admin, servidor, app que recebe e CLI do escrow só reembrulham o que `pode_reembrulhar` permite na cadeia verificada (G§5.4). A CLI ainda confere a impressão digital do aparelho (correção de S1) | Fantasma de admin + liberação de histórico assinada por ele (linha acima): a CLI mostra o registro que autoriza e pede confirmação |
| **Admin malicioso** | Por desenho pode adicionar qualquer pessoa da organização (até 100), liberar o histórico que tem, remover, encerrar, renomear. Não consegue: assinar mensagem como outro (§10.3), ler grupo de que não participa, esconder o que fez (registro assinado visível a todos), adicionar sem que o novo membro apareça | Vazar o histórico liberando-o para um cúmplice da organização. Governança: a liberação é registrada e mostrada |
| **Membro removido ou que saiu** | Época nova sem ele (na hora, se o admin remove; no próximo envio nos demais casos), e o app de quem envia recusa enviar em época que o inclui (G§2.7). D11: nada do grupo fica no aparelho dele | O que ele leu enquanto era membro |
| **Moderador** | Assina só criar, remover e encerrar (G§2.4): não adiciona ninguém a grupo existente nem libera histórico. Grupo que ele cria mostra a lista inteira a todos os membros | Lê tudo com o escrow, como na v1 (§5 de `ameacas.md`) |
| **Chave do moderador roubada** (pendrive + senha) | Junto com o servidor: criar grupos "oficiais" com membros escolhidos, remover membros, encerrar grupos. Sozinha: nada, os registros precisam ser gravados no banco | Grupo oficial falso com um usuário controlado pelo atacante: os membros veem a lista. Troca da chave exige fixar de novo em todos os aparelhos |
| **Servidor troca a chave do moderador** | Fixada pelo QR v=2 ou por canal fora do servidor (G§3.4); grupos ficam desligados sem ela | Usuário que confirma o código sem conferir |
| **Servidor adivinha o nome do grupo** pelo `meta_commit` | `salt` de 32 bytes no texto claro | Tamanho do nome em blocos de 256 bytes |
| **Repetição de registro** em outro grupo ou posição | `conversation_id`, `n` e `prev_hash` assinados | — |
| **Repetição da revogação pré-assinada** | G§8.4 | Quem tem o aparelho revoga o próprio aparelho |
| **QR reativado visto por outra pessoa** | Uso único, prazo curto, aviso da CLI; quem recebe "convite inválido" avisa o moderador | O mesmo de "QR fotografado" em `ameacas.md` §8, agora também em reativações |
| **Metadados para o servidor** | — | Quem está em que grupo, papéis, quando entrou e saiu, tamanho do grupo, `admin_label` dos oficiais, quem está ativo |

## 13. Vetores e código de referência

`docs/vetores/grupos/` (binário em hexadecimal minúsculo, salvo `_b64u` e exemplos de JSON do fio):

| Arquivo | Conteúdo |
|---------|----------|
| `chaves.json` | chave do moderador; aparelhos D (Marcos) e E (Paula) com certificados; ids de usuários; QR v=2, QR de fixação, código com `m`, QRs que devem ser recusados |
| `cadeia.json` | grupo comum com os 7 tipos (8 registros: bytes, assinatura, hash, estado depois de cada um, consultas `membro_em`/`pode_reembrulhar`); grupo oficial do moderador; 21 casos `deve_falhar` com código e posição (assinatura errada, `prev_hash` quebrado, autor sem papel, membro acima do limite, e os demais da tabela G§2.6) |
| `epoca.json` | épocas 1 e 2 do grupo comum com `chain_n`/`chain_hash`, embrulhos com chave efêmera fixa, metadados cifrados, liberação de histórico para D, épocas recusadas pela cadeia |
| `selada.json` | mensagens seladas em três tamanhos, alfabeto, evento `member_access`, `access-events`, erro `sender_inactive` |
| `revogacao.json` | revogação pré-assinada de A e casos que devem falhar |

Os aparelhos A, B e C, o servidor e o escrow vêm de `docs/vetores/chaves.json` e `cadastro.json`.

Gerar (a partir de `server/`):

```bash
go run ./internal/testvec/gengrupos ../docs/vetores
```

O gerador confere cada valor ao gerar (abre embrulhos, verifica cadeias, confere que cada caso
inválido falha com o código esperado). `go test ./internal/testvec/gengrupos` regenera em memória e
falha se os arquivos estiverem desatualizados; `go test ./internal/proto` lê os vetores e refaz
bytes, hashes, assinaturas, estados, épocas, metadados, seladas e revogação.

Código de referência em `server/internal/proto/`:

| Arquivo | Conteúdo |
|---------|----------|
| `group.go` | `ChangeBytes`, `DecodeChange`, `SignChange`, `ChangeHash`, corpos (`CreateBody`, `AddBody`, `UsersBody`, `RenameBody`, `ParseBody`), códigos de erro |
| `group_chain.go` | `GroupState`, `Apply`, `VerifyChain`, `MemberAt`, `MayRewrap`, `GroupEpochBytes`, `CheckGroupEpoch` |
| `group_meta.go` | `MetaCommit`, `MetaAAD`, `SealMeta`, `OpenMeta` |
| `group_access.go` | `SealedMessage`, `Scramble`, `NewSealed`, `MemberAccessEvent`, `AccessEvent`, `SelfRevokeBytes`, `VerifySelfRevoke`, `InviteURIMod`, `PinURI`, `ServerCodeMod` |

Testes que as fases devem ter:
- **G-B (Go):** os de `proto` já existem; mais integração das rotas de G§10 contra Postgres real,
  incluindo cada `deve_falhar` de `cadeia.json` enviado a `POST /v1/groups/{id}/changes` (400
  `chain_invalid` com o `reason` certo) e a selagem por autor inativo.
- **G-C (Dart):** ler os cinco arquivos com `sodium_libs`, refazer bytes e hashes, verificar cadeias e
  recusar todo `deve_falhar`, abrir embrulhos e metadados, recusar os QRs inválidos, gerar o mesmo
  `scramble`.
- **G-D:** estender `docs/vetores/conferir.py` para conferir os vetores de grupo com libsodium.

## 14. Mudanças em arquivos existentes

Para a G-B e a G-C aplicarem (esta fase não editou nenhum arquivo existente).

### `docs/protocolo.md`
- §1/§2.1: acrescentar os 8 rótulos de G§1 à tabela, apontando para este documento.
- §2.2: corpo HTTP de 256 KiB nas rotas de G§1; `conversation_id` de grupo gerado pelo criador.
- §3: chave `mod_sign` na tabela de chaves; definição de "membro ativo" (G§7.1) ao lado de "aparelho ativo".
- §4.2: QR `v=2` com `m`; QR `direct://pin` (G§3.2, G§3.4). §4.3: código com `m` (G§3.3).
  `GET /v1/server-info` com `mod_pub`.
- §5.5 passo 3: fixar `mod_sign_pub`; gerar a revogação pré-assinada (G§8.2).
- §8: `Conversation` com `kind: "group"` e campos de G§10.5.
- §9: remeter a G§5 para épocas de grupo (`group_epoch_bytes`, `EpochItem` com `chain_n`/`chain_hash`,
  validação G§5.2); §9.5 com `S` da cadeia; §9.7 lotes menores para itens de grupo.
- §10.6: passo extra "grupo encerrado"; §10.7 passo 3 para grupos (G§11, item 5); §10.8: parâmetro
  `before` e mensagens seladas.
- §11.3/§11.5: eventos `group_change` e `member_access`.
- §12: `self-revoke` e transições em `user_access_events`; varredura de vencimento a cada minuto.
- §13.3: `rewrap` de épocas de grupo só com `pode_reembrulhar` (G§5.4), junto com a correção de S1.
- §14: códigos de G§10.6. §16: vetores `grupos/`. §17: fluxos de grupo. §18.5/§18.6: `sender_inactive`.
- §13.1: o mesmo formato de arquivo serve à chave do moderador com magia `direct-modkey-v1`.

### `docs/ameacas.md`
- §1 resumo: linha "Admin de grupo" e ajuste de "Invasor do servidor" (fantasma de admin em grupo).
- §3, §5, §6: as linhas de G§12. §9: obrigações de G-B, G-C e G-D (cadeia, âncora, A1 antes de grupos,
  filtro de reembrulho).

### `docs/PLANO.md`
- §10: comandos de G§10.4 (`moderator init/register/qr`, `group … --mod-key`, detalhes de `reactivate`).
- §5 ou §3: chave do moderador ao lado do escrow (guarda, pendrive).
- §16: apontar para este documento.

### `docs/grupos.md`
- §2: a chave do moderador é fixada pelo QR v=2 ou pelo QR de fixação, não "já" no cadastro atual.
- §3: o moderador remove e encerra, mas não adiciona, promove nem renomeia; admin não se remove (sai).
- §8: rotas e tabelas de G§10 no lugar das três rotas e da tabela proposta.

### `docs/revisao-seguranca.md`
- S1: a correção vale para grupos com o filtro da cadeia (G§5.4). A1: pré-requisito para liberar
  grupos (G§12). A2: resolvido para grupos pela cadeia (G§2.7, passo 3); continua valendo para 1:1.

### `server/`
- `internal/store/migrations/`: migração nova com G§10.2.
- `internal/server/`: rotas de G§10.1; limite de 256 KiB por rota; filtro de seladas no histórico;
  `member_access`; `self-revoke`; varredura de vencimento; limite de aparelhos ativos por usuário
  (4, recomendado) em `/v1/enroll`.
- `internal/proto/escrow.go`: generalizar `sealEscrow`/`OpenEscrow` para receber a magia (escrow ou
  moderador).
- `internal/proto/invite.go`: a CLI passa a usar `InviteURIMod` quando há `mod_pub`.
- `cmd/direct-admin/`: comandos de G§10.4; `escrow rewrap` com filtro de grupo.

### `app/`
- Leitor de convite: aceitar `v=2` com `m` e `direct://pin` (G§3.2, G§3.4).
- Cofre/cadastro: revogação pré-assinada (G§8.2) e envio no "Esqueci a senha".
- Banco local: tabela de âncoras de grupo; nenhuma tabela de conteúdo de grupo.
- `android/app/src/main/res/xml/`: excluir o arquivo da revogação do backup (junto com A5).

## 15. Notas da implementação no servidor e na CLI (G-B)

Onde o texto acima tinha lacuna ou contradição, o servidor segue o que está aqui.

### Formatos de fio (valem para a G-C)
- `GET /v1/groups/{id}/changes` → `{"changes": [forma de G§2.8], "has_more": bool}`.
- `GET /v1/conversations/{id}/epochs/mine` → `{"items": [...], "has_more": false}`: tudo, sem paginar.
- `GET /v1/conversations/{id}/access-events` → até 500 por resposta.
- `messages?before=<seq>`: as `limit` mais novas com `seq < before`, em ordem crescente; `has_more` =
  há mais antigas.
- `POST /v1/groups/{id}/history-wraps`: `{"add_n": n, "items": [{"epoch", "device_id",
  "wrapped_key"}]}` → 201 `{"accepted": k}`. Item já gravado é ignorado; item proibido recusa o
  pedido inteiro (400).
- `reason` de `chain_invalid` e `chain_n` de `chain_conflict` vão dentro de `error`, como
  `latest_epoch`.
- `/v1/enroll` com 4 aparelhos ativos: 409 `device_limit`, convite continua sem uso (G§1 só
  recomendava o limite).

### Ordem das conferências
- `POST /v1/groups/{id}/changes`: membro (403) → registro decodifica (`formato`) → autor é o
  aparelho autenticado, nunca o moderador (403) → posição (409) → encerrado (409) → `Apply`. Por
  isso, ao contrário do que G§13 dava a entender, alguns `deve_falhar` recebem 403 ou 409 antes de
  `chain_invalid`. Nada é gravado em nenhum caso.
- Num registro com época, destinatários errados dão 409 `device_set_changed` e número de época errado
  409 `epoch_conflict` (G§10.1 dizia 400): são os erros que o app já repete.
- Upload de blob em grupo encerrado: 409 `group_closed`.
- Liberação de histórico: qualquer admin atual; grupo encerrado recusa; o aparelho de destino tem de
  estar ativo. Cada aparelho recebe no máximo 16 eventos `epoch` por pedido (a fila da conexão tem 64
  quadros): ao receber época anterior à própria entrada, o app deve buscar
  `/v1/conversations/{id}/epochs/mine`.

### Eventos
- `member_access` e os `group_change` da CLI saem por `NOTIFY`. Se o `LISTEN` do `directd` cair, ao
  voltar ele fecha todos os WebSockets com 1001: o app reconecta e busca tudo de novo.
- `POST /v1/groups` envia `conversation` e `epoch`; `group create` da CLI envia `conversation` e
  `group_change`.
- Mensagem cujo autor ficou inativo entre a gravação e o envio sai selada pelo WebSocket.

### Banco
- `conversation_members.joined_n` é `NOT NULL DEFAULT 0` (0 = conversa direta), porque faz parte da
  chave primária.
- `devices.revoke_signed_at`: o `created_at` da revogação pré-assinada (G§8.3, passo 4).
  `revoked_reason = 'expired'` existe no esquema e não é usado: vencimento não preenche `revoked_at`.
- `token revoke` marca `revoked_at` em vez de apagar o convite.

### `token reactivate`
Recusa convite pendente (nem usado nem vencido), revogado, de usuário desativado e `--new-user` que
nunca foi usado.

### `escrow rewrap` de grupos
- O grupo inteiro fica de fora se a cadeia não confere, se o topo difere do registrado na conversa ou
  se alguma época aponta para um registro que não está nela.
- A assinatura da época é conferida com o `sign_pub` do certificado (assinado pelo servidor), e
  `chain_n` não pode diminuir (G§5.2, passo 5).
- Resto: `mod_pub` vem do banco; e quem apagar do banco o fim da cadeia **e** as épocas posteriores
  volta o grupo a um estado antigo, em que um removido ainda é membro. Ele recupera só as chaves da
  época em que era membro. A lista com o registro que autoriza é a última conferência.
