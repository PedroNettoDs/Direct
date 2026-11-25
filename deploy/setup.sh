#!/usr/bin/env bash
# Instalador do servidor Direct. Roda no contêiner "setup" (docker compose run --rm setup), como root e
# sem rede. Rodar de novo não troca segredo nem chave sem resposta "sim".
#
# Montagens: /deploy (pasta deploy/), /project (o projeto, só leitura), /pendrive,
# /var/lib/postgresql/data (deploy/data/postgres) e /data (deploy/data/directd).
set -euo pipefail
umask 077

PGDATA=/var/lib/postgresql/data
SECRETS=/deploy/secrets
SOCKET=/var/run/postgresql
APP=65532      # usuário do directd e do cloudflared
PGGROUP=999    # grupo do postgres
HOST_OWNER=$(stat -c %u:%g /deploy)   # dono da pasta no servidor

die() { echo "erro: $*" >&2; exit 1; }
# ask PERGUNTA: lê uma linha para $REPLY (sem os espaços das pontas)
ask() { printf '%s' "$1" >&2; read -r REPLY || die "entrada encerrada"; }
confirm() { ask "$1 (sim/não): "; [[ ${REPLY,,} == sim ]]; }
sql() { psql -qtA -h "$SOCKET" -U direct -d direct -c "$1"; }

pg='' dd='' used_pendrive='' pendrive_ok=''
cleanup() {
	[[ -z $dd ]] || { kill "$dd" 2>/dev/null; wait "$dd" 2>/dev/null; } || true
	[[ -z $pg ]] || { kill -INT "$pg" 2>/dev/null; wait "$pg" 2>/dev/null; } || true
	if [[ -n $used_pendrive ]]; then
		printf '\n>>> RETIRE O PENDRIVE (%s) e guarde fora do servidor. Faça uma segunda cópia offline.\n' "$DIRECT_PENDRIVE" >&2
		echo ">>> Desmonte antes de puxar (umount ou \"ejetar\")." >&2
	fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# O serviço postgres segura esta mesma trava: dois PostgreSQL sobre a pasta corromperiam o banco.
exec 9<"$PGDATA"
flock -n 9 || die "o banco está em uso. Pare os serviços antes: docker compose stop"

# Chave privada nunca dentro do projeto (compara o diretório em si, não o texto do caminho).
if [[ -d /pendrive && -n $(find /project -type d -samefile /pendrive -print -quit) ]]; then
	die "DIRECT_PENDRIVE=$DIRECT_PENDRIVE está dentro da pasta do projeto. Use um pendrive."
fi

# need_pendrive ARQUIVO: exige o pendrive e não deixa sobrescrever
need_pendrive() {
	[[ -d /pendrive ]] || die "falta o pendrive. Rode: DIRECT_PENDRIVE=/caminho/do/pendrive docker compose run --rm setup"
	if [[ -z $pendrive_ok && $(stat -c %d /pendrive) == "$(stat -c %d /project)" ]]; then
		echo "AVISO: $DIRECT_PENDRIVE está no mesmo disco do projeto, não parece um pendrive." >&2
		echo "A chave privada ficaria no servidor." >&2
		confirm "Usar mesmo assim?" || die "monte o pendrive e rode de novo"
	fi
	pendrive_ok=1
	[[ ! -e /pendrive/$1 ]] || die "$DIRECT_PENDRIVE/$1 já existe; não sobrescrevo. Mova-o ou use outro pendrive."
}

# ---- pastas e segredos ----
mkdir -p "$SECRETS"
chown "$HOST_OWNER" "$SECRETS" /deploy/data
chmod 700 "$SECRETS" /deploy/data
chown "$APP:$APP" /data
chmod 700 /data

f=$SECRETS/db_password
if [[ ! -s $f ]] || confirm "Senha do banco já existe. Gerar outra?"; then
	head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n' >"$f"
	echo "Senha do banco gerada."
fi
chown "$APP:$PGGROUP" "$f"   # lida pelo directd (dono) e pelo postgres (grupo)
chmod 640 "$f"

f=$SECRETS/cf_tunnel_token
if [[ ! -s $f ]] || confirm "Token do túnel já gravado. Substituir?"; then
	while :; do
		printf 'Cole o token do Cloudflare Tunnel (não aparece na tela): ' >&2
		read -rs token || die "entrada encerrada"
		echo >&2
		[[ $token =~ ^[A-Za-z0-9_=+/.-]+$ ]] && break
		echo "Cole só o token (começa com eyJ), sem o comando em volta." >&2
	done
	printf '%s' "$token" >"$f"
	unset token
	echo "Token gravado."
fi
chown "$APP:$APP" "$f"
chmod 600 "$f"

envfile=/deploy/.env
host=$(sed -n 's/^DIRECT_PUBLIC_HOST=//p' "$envfile" 2>/dev/null || true)
if [[ -z $host ]] || confirm "Domínio atual: $host. Trocar?"; then
	while :; do
		ask "Domínio público (ex.: direct.exemplo.com.br): "
		host=${REPLY,,}
		[[ $host =~ ^([a-z0-9-]+\.)+[a-z0-9-]+$ ]] && break
		echo "Só o domínio: sem https://, porta ou barra." >&2
	done
	{ grep -v '^DIRECT_PUBLIC_HOST=' "$envfile" 2>/dev/null || true; echo "DIRECT_PUBLIC_HOST=$host"; } >"$envfile.tmp"
	mv "$envfile.tmp" "$envfile"
fi
chown "$HOST_OWNER" "$envfile"
chmod 600 "$envfile"

# ---- banco e directd temporários (só socket local: o contêiner não tem rede) ----
echo "Preparando o banco..."
POSTGRES_USER=direct POSTGRES_DB=direct POSTGRES_PASSWORD="$(<"$SECRETS/db_password")" \
	docker-entrypoint.sh postgres -c listen_addresses='' </dev/null >/tmp/postgres.log 2>&1 &
pg=$!
# Na primeira vez o entrypoint sobe antes um servidor provisório; só o definitivo tem o PID $pg.
until [[ $(head -n1 "$PGDATA/postmaster.pid" 2>/dev/null) == "$pg" ]] && pg_isready -q -h "$SOCKET"; do
	kill -0 "$pg" 2>/dev/null || { cat /tmp/postgres.log >&2; pg=''; die "o PostgreSQL não subiu"; }
	sleep 0.5
done
# Mantém o banco igual ao arquivo, inclusive depois de gerar outra senha.
psql -q -v ON_ERROR_STOP=1 -h "$SOCKET" -U direct -d direct <<'SQL'
\set pw `cat /deploy/secrets/db_password`
ALTER ROLE direct PASSWORD :'pw';
SQL

export DIRECT_DB_URL="host=$SOCKET user=direct dbname=direct sslmode=disable"
export DIRECT_ADMIN_LOG=/data/admin.log

# O directd cria as tabelas e a chave de assinatura do servidor na primeira subida.
DIRECT_SERVER_SIGN_KEY_FILE=/data/server_sign.key DIRECT_LISTEN=127.0.0.1:8080 \
	gosu "$APP:$APP" directd </dev/null >/tmp/directd.log 2>&1 &
dd=$!
until grep -qs 'directd ouvindo' /tmp/directd.log; do
	kill -0 "$dd" 2>/dev/null || { cat /tmp/directd.log >&2; dd=''; die "o directd não subiu"; }
	sleep 0.5
done

# Registro de comandos só de acréscimo (revisão de segurança, S8).
if [[ ! -e $DIRECT_ADMIN_LOG ]]; then
	: >"$DIRECT_ADMIN_LOG"
	chown "$APP:$APP" "$DIRECT_ADMIN_LOG"
	chmod 600 "$DIRECT_ADMIN_LOG"
fi
chattr +a "$DIRECT_ADMIN_LOG" 2>/dev/null ||
	echo "AVISO: não deu para marcar o registro como só de acréscimo. No servidor: sudo chattr +a deploy/data/directd/admin.log" >&2

# ---- chaves privadas no pendrive; no servidor, só as públicas ----
give_to_pendrive_owner() { chown "$(stat -c %u:%g /pendrive)" "/pendrive/$1" 2>/dev/null || true; }

if [[ $(sql 'SELECT escrow_pub IS NOT NULL FROM server_keys') == t ]]; then
	echo "Escrow já configurado (a chave não é trocada)."
else
	need_pendrive escrow.key
	echo
	echo "== Chave de escrow (lê todo o histórico) =="
	used_pendrive=1
	direct-admin escrow init --out /pendrive/escrow.key
	give_to_pendrive_owner escrow.key
fi

modpub=/deploy/data/moderador.pub
if [[ ! -s $modpub ]] || confirm "Chave do moderador já gerada. Gerar outra? (só antes de registrá-la)"; then
	need_pendrive moderador.key
	echo
	echo "== Chave do moderador (assina grupos). Use uma senha diferente da de escrow. =="
	used_pendrive=1
	direct-admin moderator init --out /pendrive/moderador.key | tee /tmp/moderator.out
	give_to_pendrive_owner moderador.key
	sed -n 's/^mod_sign_pub: //p' /tmp/moderator.out >"$modpub"
	[[ -s $modpub ]] || die "não consegui ler a chave pública do moderador"
fi
chown "$HOST_OWNER" "$modpub"
chmod 644 "$modpub"

# ---- primeiro convite ----
echo
if confirm "Criar um convite agora?"; then
	ask "Rótulo do usuário (ex.: João - Financeiro): "
	DIRECT_PUBLIC_HOST=$host direct-admin token create --new-user "$REPLY" ||
		echo "Convite não criado. Depois: docker compose exec directd /direct-admin token create --new-user \"<rótulo>\"" >&2
fi

echo
echo "Instalação concluída. Suba o servidor: docker compose up -d"
