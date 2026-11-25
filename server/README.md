# directd (servidor Direct)

API HTTP + WebSocket conforme `docs/protocolo.md`. O servidor nunca decifra conteúdo.

## Variáveis de ambiente

| Variável | Padrão | Função |
|----------|--------|--------|
| `DIRECT_DB_URL` | — | conexão completa (tem prioridade). Senão: `DIRECT_DB_HOST`, `_PORT`, `_NAME`, `_USER`, `_PASSWORD_FILE`, `_SSLMODE` (padrão `disable`) |
| `DIRECT_SERVER_SIGN_KEY_FILE` | `/data/server_sign.key` | semente Ed25519 (32 bytes, 0600); criada na primeira subida |
| `DIRECT_LISTEN` | `:8080` | endereço de escuta |
| `DIRECT_TRUSTED_IP_HEADER` | vazio | cabeçalho com o IP do cliente (`CF-Connecting-IP`); só ligar atrás do Cloudflare |
| `DIRECT_TRUSTED_PROXY` | vazio | nome ou IP do único par de quem o cabeçalho acima vale (`cloudflared`); sem ele o cabeçalho é ignorado |

As migrações (goose, embutidas) rodam na subida. `escrow_pub` em `server_keys` é gravado pela CLI
(`direct-admin escrow init`); sem ele `/v1/server-info` e criação de época respondem 503 `unavailable`.

## Imagens (protocolo seção 18)

`POST /v1/blobs?conversation_id=`, `GET /v1/blobs/{id}`, `POST /v1/media/saves`. O blob cifrado
(até 10 MiB) fica em `blobs.data` (`bytea`, migração `00002_media.sql`): mesmo volume cifrado do
banco, entra no `pg_dump` e no backup `age`, apaga com a conversa e não cria arquivo avulso para
sincronizar. Custo: o TOAST do PostgreSQL guarda os blobs fora da linha, então o banco cresce com as
fotos; se isso pesar, migrar para arquivos exige só trocar `store.InsertBlob`/`GetBlob`.
Cota de 1 GiB por usuário por dia. Uploads órfãos (blob sem mensagem) ficam no banco até
`direct-admin media prune [--older 30d]`, que apaga os sem mensagem posterior do mesmo aparelho na
conversa.

## CLI do moderador (`direct-admin`)

Comandos na seção 10 do `docs/PLANO.md` (`direct-admin` sem argumentos lista todos). Fala direto com o
banco, com as mesmas variáveis `DIRECT_DB_*` do `directd`, e não roda migrações. Suba o `directd`
uma vez antes (ele grava `server_sign_pub`).

| Variável | Padrão | Função |
|----------|--------|--------|
| `DIRECT_PUBLIC_HOST` | — | domínio público que vai no QR (ou `--host` em `token create`) |
| `DIRECT_ADMIN_LOG` | `~/.direct-admin.log` (na imagem: `/data/admin.log`) | registro de comandos, só acréscimo; sem ele o comando não roda. Para impedir edição: `chattr +a` |
| `DIRECT_ADMIN_OPERATOR` | `SUDO_USER` ou usuário do sistema | nome do moderador no registro |

No servidor, pela imagem:

```bash
docker compose -f deploy/docker-compose.yml exec -e DIRECT_PUBLIC_HOST=direct.exemplo.com.br -e DIRECT_ADMIN_OPERATOR=maria directd /direct-admin token create --new-user "João - Financeiro"
```

**Instalação.** `deploy/README.md`: o serviço `setup` do compose roda `escrow init` e `moderator init`
com a chave privada direto no pendrive.

**Moderador.** `moderator init --out <arquivo>` gera a chave de assinatura de grupos
(`docs/protocolo-grupos.md` 3.1) e não precisa do banco. Com o banco configurado, imprime também o
código de verificação. `moderator register --pub <mod_sign_pub>` grava só a pública, uma vez; com o
instalador, ela está em `deploy/data/moderador.pub`:

```bash
docker compose -f deploy/docker-compose.yml exec directd /direct-admin moderator register --pub "$(cat deploy/data/moderador.pub)"
```

**Só registre depois que todos tiverem o app com grupos:** a partir daí os convites saem como QR
`v=2`, que a versão anterior do app recusa. Não há troca de chave nem como desregistrar.

**Grupos.** `group list` e `group show` só leem. `group create`, `remove-member` e `close` assinam com a
chave do pendrive (`--mod-key`): rode no notebook do moderador, por túnel SSH, como o `rewrap`.
`escrow rewrap` também devolve épocas de grupo, só as que a cadeia assinada permite.

**Recadastro.** `token reactivate <id> --ttl 24h` reabre um convite usado ou vencido para o mesmo
usuário. O QR não é reimpresso: o servidor não guarda a semente.

**Convites.** `--ttl` vai até 7 dias. `token revoke` marca o convite como revogado (não apaga).

**Rewrap.** `escrow rewrap` pede duas confirmações (`sim`): o código do aparelho, que o moderador
compara com o de Ajustes no aparelho novo por outro canal, e a lista de conversas (protocolo 13.3).
Entram só as conversas com alguma época assinada que inclua um aparelho do usuário; delas, todas as
épocas, inclusive as criadas enquanto ele estava sem aparelho.

**Escrow.** Rode `escrow rewrap` (e `escrow init`, se não usar o instalador) no notebook do moderador, com o banco alcançado por
túnel SSH (`docs/ameacas.md` §3): assim a chave privada e a senha nunca passam pelo servidor. Aponte
`DIRECT_DB_HOST`/`_PORT` para a ponta local do túnel (o compose não publica a porta do Postgres:
o destino do `ssh -L` é o IP do contêiner na máquina do servidor). `init` recusa senha com menos de 16
caracteres, nunca sobrescreve arquivo e só registra a pública depois de gravar o arquivo. A senha é lida
sem eco do terminal (ou uma linha por vez da entrada padrão, se não houver terminal).

**Revogação.** O aparelho também pode se revogar sem login (`POST /v1/devices/self-revoke`). `device revoke` e `user disable` marcam `revoked_at`, apagam tokens e desafios e fazem
`pg_notify('device_revoked', ...)`; o `directd` fecha os WebSockets com 4003. `user disable` também
apaga convites pendentes do usuário. `token revoke` apaga um convite ainda não usado.

## Testes

```bash
export PATH=$HOME/sdk/go/bin:$PATH
docker run -d --rm --name direct-test-pg -e POSTGRES_USER=direct -e POSTGRES_PASSWORD=test -e POSTGRES_DB=direct -p 127.0.0.1:55432:5432 postgres:17
DIRECT_TEST_DB_URL='postgres://direct:test@127.0.0.1:55432/direct?sslmode=disable' go test ./...
```

Sem `DIRECT_TEST_DB_URL` os testes de integração são pulados (`SKIP`); os de `proto` rodam sempre.
Cada teste cria e apaga um schema próprio. Os vetores de `docs/vetores/*.json` são verificados em
`internal/proto` (bytes e assinaturas) e reexecutados ponta a ponta em `internal/server`
(o certificado, a época e a mensagem dos vetores passam pelo servidor de verdade).
