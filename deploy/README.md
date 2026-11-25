# Instalação do servidor Direct

Três serviços no Docker Compose: `postgres`, `directd` e `cloudflared`. Um quarto, `setup`, é o
instalador: só roda quando chamado, sem rede. Nenhuma porta é publicada no host.

Rode os comandos desta página dentro de `deploy/`.

## 1. Pré-requisitos

- Linux com Docker Engine e Docker Compose v2, e um usuário que possa usar o `docker`.
- O projeto num sistema de arquivos Linux (ext4, XFS, Btrfs), para o `chattr +a` do registro de comandos.
- Um domínio já na conta da Cloudflare.
- Um pendrive para as chaves privadas.

## 2. Túnel no painel da Cloudflare

Passo a passo completo em [`docs/cloudflare.md`](../docs/cloudflare.md). Em resumo:

1. Crie um túnel do tipo **Cloudflared** e copie **só o token** (começa com `eyJ`). Não rode o comando
   mostrado.
2. Publique o endereço (ex.: `direct.exemplo.com.br`) com Service URL `http://directd:8080`.
3. Não ponha Cloudflare Access nesse endereço e deixe o Bot Fight Mode desligado.

## 3. Pendrive

O instalador grava nele `escrow.key` (lê todo o histórico) e `moderador.key` (assina mudanças de
grupo), cada um cifrado com uma senha de 16 caracteres ou mais. Use senhas diferentes. O servidor
recebe só as chaves públicas.

Monte o pendrive e anote o caminho (`lsblk` mostra; costuma ser `/media/<usuário>/<nome>`). O
instalador recusa caminho dentro do projeto e avisa se o caminho estiver no mesmo disco do projeto.

## 4. Instalar e subir

```bash
docker compose --profile setup build
DIRECT_PENDRIVE=/media/usuario/PENDRIVE docker compose run --rm setup
docker compose up -d
docker compose exec directd /direct-admin moderator register --pub "$(cat data/moderador.pub)"
docker compose exec directd /direct-admin token create --new-user "João - Financeiro"
```

O `setup` pede o token do túnel (não aparece na tela), o domínio e as senhas das duas chaves.

Em instalação nova, responda **não** quando o `setup` oferecer criar um convite. O convite criado
antes do `moderator register` sai no formato v=1, sem a chave do moderador, e esse aparelho ficaria
sem grupos até ler o QR de `direct-admin moderator qr`. Por isso registre a chave do moderador
primeiro, como na ordem acima. O registro mostra um código de verificação. O convite vale 24 h e
mostra o QR no terminal.

No fim, **desmonte e retire o pendrive**, faça uma segunda cópia offline e guarde longe do servidor.

Conferir: `docker compose ps` e `https://<domínio>/v1/server-info`, que devolve `server_sign_pub` e
`escrow_pub`.

**Rodar o `setup` de novo.** Pare antes os serviços (`docker compose stop`). Sem pendrive basta
`docker compose run --rm setup`. Nada é trocado sem você responder `sim`. A chave de escrow não pode
ser trocada. A do moderador só pode ser gerada de novo antes de ser registrada, e nunca por cima de um
arquivo existente.

**Chave do moderador.** A pública fica em `data/moderador.pub`. Depois do `moderator register` ela
não pode mais ser trocada.

**Convites e moderação**, com o servidor no ar:

```bash
docker compose exec -e DIRECT_ADMIN_OPERATOR=maria directd /direct-admin token create --new-user "João - Financeiro"
```

Os demais comandos estão na seção 10 de `docs/PLANO.md`. O `escrow rewrap` roda no notebook do
moderador (`server/README.md`).

## 5. Onde ficam os dados

| Caminho em `deploy/` | Conteúdo | Dono (uid:gid) |
|----------------------|----------|----------------|
| `data/postgres/` | banco: mensagens e imagens cifradas, usuários, aparelhos, convites | 999 |
| `data/directd/server_sign.key` | chave de assinatura do servidor | 65532 |
| `data/directd/admin.log` | registro de comandos do `direct-admin`, só de acréscimo | 65532 |
| `data/moderador.pub` | chave pública do moderador | seu usuário |
| `secrets/db_password` | senha do banco | 65532:999 |
| `secrets/cf_tunnel_token` | token do túnel | 65532 |
| `.env` | `DIRECT_PUBLIC_HOST` | seu usuário |

Tudo isso fica fora do git. Para ler ou copiar o que é de outro dono é preciso `sudo`.

**Registro de comandos.** O `setup` marca `admin.log` com `chattr +a`. Confira com
`sudo lsattr data/directd/admin.log` (deve aparecer `a`). Se o instalador avisou que não conseguiu,
rode `sudo chattr +a data/directd/admin.log`. Comandos rodados no notebook do moderador
(`escrow rewrap`) ficam no `~/.direct-admin.log` de lá.

## 6. Parar, subir e atualizar

```bash
docker compose stop      # para
docker compose up -d     # sobe
docker compose down      # apaga os contêineres; os dados continuam em data/
```

Para atualizar o código: `docker compose --profile setup build` e depois `docker compose up -d`.

Para apagar a instalação de propósito: `docker compose down`, `sudo chattr -a data/directd/admin.log`,
`sudo rm -rf data secrets .env`. Não tem volta.

Quem usou o compose antigo, com volumes do Docker (`deploy_pgdata`): os dados de lá não são migrados.
Responda `sim` quando o `setup` perguntar se deve gerar outra senha do banco.

## Avisos

- `data/` guarda a **chave de assinatura do servidor** e **metadados** em claro: quem fala com quem,
  quando, tamanhos, nomes, rótulos e aparelhos. O conteúdo das mensagens fica cifrado.
- Por decisão do projeto **não há LUKS nem backup periódico**. Disco roubado expõe esses metadados e
  a chave do servidor; disco perdido leva tudo. A única cópia é a própria pasta `data/`. Se copiar,
  pare os serviços antes e use `sudo cp -a`.
