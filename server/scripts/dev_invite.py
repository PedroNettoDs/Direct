#!/usr/bin/env python3
"""DEV ONLY (substitui `direct-admin` até a F3): grava um convite no Postgres de teste e imprime a URI do QR.
uso: dev_invite.py <host> [admin_label] [container=direct-test-pg]
Gera escrow_pub aleatório se server_keys ainda não tem (a chave privada é descartada: só serve para teste)."""
import base64, os, subprocess, sys, uuid
import nacl.signing, nacl.public

host = sys.argv[1]
label = sys.argv[2] if len(sys.argv) > 2 else "Teste Dev"
ctr = sys.argv[3] if len(sys.argv) > 3 else "direct-test-pg"
b64 = lambda b: base64.urlsafe_b64encode(b).rstrip(b"=").decode()

def psql(sql):
    return subprocess.run(["docker", "exec", "-i", ctr, "psql", "-U", "direct", "-d", "direct", "-At", "-v", "ON_ERROR_STOP=1"],
                          input=sql, text=True, capture_output=True, check=True).stdout.strip()

seed = os.urandom(32)
pub = bytes(nacl.signing.SigningKey(seed).verify_key)
esc = bytes(nacl.public.PrivateKey.generate().public_key)
psql(f"UPDATE server_keys SET escrow_pub = '\\x{esc.hex()}' WHERE escrow_pub IS NULL;")
psql(f"INSERT INTO enrollment_tokens (id, invite_pub, user_id, admin_label, expires_at, device_ttl) "
     f"VALUES ('{uuid.uuid4()}', '\\x{pub.hex()}', NULL, '{label.replace(chr(39), '')}', now() + interval '24 hours', interval '180 days');")
srv = bytes.fromhex(psql("SELECT encode(server_sign_pub,'hex') FROM server_keys;"))
esc = bytes.fromhex(psql("SELECT encode(escrow_pub,'hex') FROM server_keys;"))
print(f"direct://enroll?v=1&h={host}&t={b64(seed)}&s={b64(srv)}&e={b64(esc)}")
