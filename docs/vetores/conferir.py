#!/usr/bin/env python3
"""Confere os vetores de docs/vetores/*.json com libsodium (via PyNaCl).

libsodium é a mesma biblioteca que o app usa por baixo do `sodium_libs`. Se este script
passa, os bytes gerados pelo Go (golang.org/x/crypto) batem com libsodium.

Uso: python3 docs/vetores/conferir.py   (requer: pip install pynacl)
"""
import json
import pathlib
import sys

import nacl.bindings as s
import nacl.exceptions
import nacl.pwhash.argon2id as argon2id
import nacl.signing

D = pathlib.Path(__file__).resolve().parent
h = bytes.fromhex
falhas = 0


def ok(cond, oque):
    global falhas
    print(("ok    " if cond else "FALHA ") + oque)
    if not cond:
        falhas += 1


def h_b64(t):
    import base64
    return base64.urlsafe_b64decode(t + "=" * (-len(t) % 4))


def carregar(nome):
    return json.loads((D / nome).read_text(encoding="utf-8"))


def blake(data, n=32):
    return s.crypto_generichash_blake2b_salt_personal(data, digest_size=n)


def assinar(seed, msg):
    return nacl.signing.SigningKey(seed).sign(msg).signature


def verifica(pub, msg, sig):
    try:
        nacl.signing.VerifyKey(pub).verify(msg, sig)
        return True
    except nacl.exceptions.BadSignatureError:
        return False


def b64u(b):
    import base64
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def sela_fixo(msg, pub, eph_sk):
    """crypto_box_seal reconstruído com chave efêmera fixa."""
    eph_pub = s.crypto_scalarmult_base(eph_sk)
    nonce = blake(eph_pub + pub, 24)
    return eph_pub + s.crypto_box(msg, nonce, pub, eph_sk)


def label(t):
    return t.encode() + b"\x00"


# ---- chaves ----
ch = carregar("chaves.json")
srv = ch["servidor"]
pk, sk = s.crypto_sign_seed_keypair(h(srv["sign_seed"]))
ok(pk == h(srv["sign_pub"]) and sk == h(srv["sign_sk_libsodium"]), "chaves: servidor Ed25519")
esc = ch["escrow"]
ok(s.crypto_scalarmult_base(h(esc["kex_sk"])) == h(esc["kex_pub"]), "chaves: escrow X25519")
dev = {}
for a in ch["aparelhos"]:
    dev[a["nome"]] = a
    pk, sk = s.crypto_sign_seed_keypair(h(a["sign_seed"]))
    ok(pk == h(a["sign_pub"]) and sk == h(a["sign_sk_libsodium"]), f"chaves: aparelho {a['nome']} Ed25519")
    ok(s.crypto_scalarmult_base(h(a["kex_sk"])) == h(a["kex_pub"]), f"chaves: aparelho {a['nome']} X25519")
    dg = blake(label("direct/v1/device-code") + h(a["sign_pub"]) + h(a["kex_pub"]))
    grupos = [f"{int.from_bytes(dg[i*5:i*5+5], 'big') % 100000:05d}" for i in range(4)]
    ok(" ".join(grupos) == a["codigo_aparelho"], f"chaves: aparelho {a['nome']} código do aparelho")
SRV_PUB, ESC_PUB, ESC_SK = h(srv["sign_pub"]), h(esc["kex_pub"]), h(esc["kex_sk"])


def uuid(u):
    return bytes.fromhex(u.replace("-", ""))


# ---- convite ----
cv = carregar("convite.json")
ipk, _ = s.crypto_sign_seed_keypair(h(cv["invite_seed"]))
ok(ipk == h(cv["invite_pub"]) and b64u(ipk) == cv["invite_pub_b64u"], "convite: invite_pub da semente")
uri = f"direct://enroll?v=1&h={cv['host']}&t={b64u(h(cv['invite_seed']))}&s={b64u(SRV_PUB)}&e={b64u(ESC_PUB)}"
ok(uri == cv["qr_uri"], "convite: URI do QR")
ent = label("direct/v1/server-code") + SRV_PUB + ESC_PUB
ok(ent == h(cv["codigo_entrada"]), "convite: entrada do código")
dg = blake(ent)
ok(dg == h(cv["codigo_blake2b256"]), "convite: BLAKE2b-256 do código")
grupos = [f"{int.from_bytes(dg[i*5:i*5+5], 'big') % 100000:05d}" for i in range(4)]
ok(" ".join(grupos) == cv["codigo_verificacao"], "convite: código de verificação")
import hashlib

# ---- cadastro ----
cd = carregar("cadastro.json")
A = dev["A"]
eb = label("direct/v1/enroll") + h(cd["invite_pub"]) + h(A["sign_pub"]) + h(A["kex_pub"])
ok(eb == h(cd["enroll_bytes"]), "cadastro: bytes do cadastro")
ok(assinar(h(cd["invite_seed"]), eb) == h(cd["invite_sig"]), "cadastro: assinatura do convite")
ok(assinar(h(A["sign_seed"]), eb) == h(cd["proof_sig"]), "cadastro: prova de posse do aparelho")
ok(cd["requisicao"]["invite_sig"] == b64u(h(cd["invite_sig"])), "cadastro: base64url da requisição")
for c in cd["certificados"]:
    d = dev[c["aparelho"]]
    lbl = d["admin_label"].encode("utf-8")
    cb = (label("direct/v1/device-cert") + uuid(d["device_id"]) + uuid(d["user_id"]) + h(d["sign_pub"])
          + h(d["kex_pub"]) + c["enrolled_at"].to_bytes(8, "big") + c["expires_at"].to_bytes(8, "big")
          + len(lbl).to_bytes(4, "big") + lbl)
    ok(cb == h(c["cert_bytes"]), f"cadastro: bytes do certificado {c['aparelho']}")
    ok(assinar(h(srv["sign_seed"]), cb) == h(c["cert_sig"]), f"cadastro: assinatura do certificado {c['aparelho']}")
for p in cd["kex_pub_ordem_baixa"]:
    try:
        s.crypto_scalarmult(h(dev["A"]["kex_sk"]), h(p))
        ok(False, f"cadastro: ponto de ordem baixa recusado {p[:8]}")
    except Exception:
        ok(True, f"cadastro: ponto de ordem baixa recusado {p[:8]}")

# ---- login ----
lg = carregar("login.json")
am = label("direct/v1/auth") + SRV_PUB + uuid(A["device_id"]) + h(lg["challenge"])
ok(am == h(lg["auth_bytes"]), "login: bytes assinados")
ok(assinar(h(A["sign_seed"]), am) == h(lg["auth_sig"]), "login: assinatura")
ok(hashlib.sha256(h(lg["access_token"])).digest() == h(lg["access_token_hash_sha256"]), "login: SHA-256 do token de acesso")
rv = label("direct/v1/revoked") + uuid(A["device_id"]) + h(lg["challenge"])
ok(rv == h(lg["revogado_bytes"]), "login: bytes da prova de revogação")
ok(assinar(h(srv["sign_seed"]), rv) == h(lg["revogado_sig"]), "login: assinatura da prova de revogação")

# ---- época ----
ep = carregar("epoca.json")
conv, n, K = uuid(ep["conversation_id"]), ep["epoch"], h(ep["chave_epoca"])
cm = blake(label("direct/v1/epoch-key") + conv + n.to_bytes(4, "big") + K)
ok(cm == h(ep["key_commitment"]), "época: key_commitment")
rec = sorted([uuid(dev["A"]["device_id"]), uuid(dev["B"]["device_id"])])
ok([r.hex() for r in rec] == [x.replace("-", "") for x in ep["recipients_ordenados"]], "época: ordem dos destinatários")
st = (label("direct/v1/epoch") + conv + n.to_bytes(4, "big") + uuid(A["device_id"]) + cm + ESC_PUB
      + len(rec).to_bytes(4, "big") + b"".join(rec))
ok(st == h(ep["statement_bytes"]), "época: bytes da declaração")
ok(assinar(h(A["sign_seed"]), st) == h(ep["statement_sig"]), "época: assinatura da declaração")
for w in ep["embrulhos"]:
    if w["destino"] == "escrow":
        pub, sk_ = ESC_PUB, ESC_SK
    else:
        pub, sk_ = h(dev[w["destino"]]["kex_pub"]), h(dev[w["destino"]]["kex_sk"])
    ct = h(w["wrapped_key"])
    ok(s.crypto_box_seal_open(ct, pub, sk_) == K, f"época: abrir embrulho {w['destino']}")
    ok(sela_fixo(K, pub, h(w["eph_sk"])) == ct, f"época: reconstruir selagem {w['destino']}")

# ---- mensagem ----
mg = carregar("mensagem.json")
plain = mg["texto_claro"].encode("utf-8")
ok(plain == h(mg["texto_claro_bytes"]), "mensagem: texto claro UTF-8")
padded = s.sodium_pad(plain, 256)
ok(padded == h(mg["texto_preenchido"]), "mensagem: sodium_pad 256")
hdr = (uuid(mg["conversation_id"]) + mg["epoch"].to_bytes(4, "big") + uuid(A["device_id"])
       + uuid(mg["message_id"]) + mg["sent_at"].to_bytes(8, "big"))
ok(hdr == h(mg["cabecalho"]), "mensagem: cabeçalho")
aad = label("direct/v1/msg") + hdr
ok(aad == h(mg["aad"]), "mensagem: AAD")
ct = s.crypto_aead_xchacha20poly1305_ietf_encrypt(padded, aad, h(mg["nonce"]), K)
ok(ct == h(mg["ciphertext"]), "mensagem: XChaCha20-Poly1305")
pt = s.crypto_aead_xchacha20poly1305_ietf_decrypt(ct, aad, h(mg["nonce"]), K)
ok(s.sodium_unpad(pt, 256) == plain, "mensagem: decifrar e sodium_unpad")
sig_in = label("direct/v1/msg-sig") + hdr + h(mg["nonce"]) + len(ct).to_bytes(4, "big") + ct
ok(sig_in == h(mg["assinado_bytes"]), "mensagem: bytes assinados")
ok(assinar(h(A["sign_seed"]), sig_in) == h(mg["signature"]), "mensagem: assinatura")
for f in mg["deve_falhar"]:
    if "aad" in f:
        try:
            s.crypto_aead_xchacha20poly1305_ietf_decrypt(h(f["ciphertext"]), h(f["aad"]), h(mg["nonce"]), K)
            ok(False, "mensagem: deve falhar: " + f["caso"])
        except nacl.exceptions.CryptoError:
            ok(True, "mensagem: deve falhar: " + f["caso"])
    else:
        ok(not verifica(h(f["sign_pub"]), h(f["assinado_bytes"]), h(f["signature"])), "mensagem: deve falhar: " + f["caso"])
for p in mg["preenchimento_bloco_256"]:
    out = s.sodium_pad(b"a" * p["entrada_len"], 256)
    ok(len(out) == p["saida_len"] and out[-4:] == h(p["saida_ultimos_bytes"]), f"mensagem: preenchimento {p['entrada_len']}")
q = mg["quadro_ws_send"]["message"]
ok(q["ciphertext"] == b64u(ct) and q["signature"] == b64u(h(mg["signature"])) and q["nonce"] == b64u(h(mg["nonce"])),
   "mensagem: base64url do quadro send")

# ---- escrow ----
es = carregar("escrow.json")
ar = es["arquivo"]
key = argon2id.kdf(32, ar["senha_utf8"].encode("utf-8"), h(ar["salt"]),
                   opslimit=ar["opslimit"], memlimit=ar["memlimit_bytes"])
ok(key == h(ar["chave_argon2id"]), "escrow: Argon2id")
hd = b"direct-escrow-v1" + ar["opslimit"].to_bytes(4, "big") + ar["memlimit_kib"].to_bytes(4, "big") + h(ar["salt"]) + h(ar["nonce"])
ok(hd == h(ar["cabecalho"]), "escrow: cabeçalho do arquivo")
fct = s.crypto_aead_xchacha20poly1305_ietf_encrypt(h(ar["escrow_sk"]), hd, h(ar["nonce"]), key)
ok(hd + fct == h(ar["conteudo_arquivo"]), "escrow: arquivo completo")
rw = es["rewrap"]
k2 = s.crypto_box_seal_open(h(rw["escrow_wrap"]), ESC_PUB, ESC_SK)
ok(k2 == h(rw["chave_epoca"]), "escrow: abrir embrulho de escrow")
C = dev["C"]
ok(sela_fixo(k2, h(C["kex_pub"]), h(rw["eph_sk"])) == h(rw["wrapped_key"]), "escrow: reconstruir rewrap para C")
ok(s.crypto_box_seal_open(h(rw["wrapped_key"]), h(C["kex_pub"]), h(C["kex_sk"])) == K, "escrow: C abre o rewrap")

# ---- anexo (imagens) ----
import hashlib

an = carregar("anexo.json")
bk, bn = h(an["chave_blob"]), h(an["nonce_blob"])
baad = label("direct/v1/blob") + uuid(an["conversation_id"])
ok(baad == h(an["aad_blob"]), "anexo: AAD do blob")
bct = s.crypto_aead_xchacha20poly1305_ietf_encrypt(h(an["imagem_bytes"]), baad, bn, bk)
ok(bn + bct == h(an["blob"]), "anexo: blob = nonce || XChaCha20-Poly1305")
ok(hashlib.sha256(h(an["blob"])).digest() == h(an["blob_sha256"]), "anexo: SHA-256 do blob")
ok(s.crypto_aead_xchacha20poly1305_ietf_decrypt(bct, baad, bn, bk) == h(an["imagem_bytes"]), "anexo: abrir blob")
am = an["mensagem"]
aplain = am["texto_claro"].encode("utf-8")
ok(aplain == h(am["texto_claro_bytes"]), "anexo: mensagem claro UTF-8")
aj = json.loads(aplain)
ok(aj["blob_id"] == an["blob_id"] and h_b64(aj["key"]) == bk and h_b64(aj["sha256"]) == h(an["blob_sha256"]),
   "anexo: mensagem aponta para o blob")
ahdr = (uuid(an["conversation_id"]) + am["epoch"].to_bytes(4, "big") + uuid(A["device_id"])
        + uuid(am["message_id"]) + am["sent_at"].to_bytes(8, "big"))
ok(ahdr == h(am["cabecalho"]), "anexo: cabeçalho da mensagem")
aaad = label("direct/v1/msg") + ahdr
ok(aaad == h(am["aad"]), "anexo: AAD da mensagem")
apad = s.sodium_pad(aplain, 256)
ok(apad == h(am["texto_preenchido"]), "anexo: sodium_pad")
act = s.crypto_aead_xchacha20poly1305_ietf_encrypt(apad, aaad, h(am["nonce"]), K)
ok(act == h(am["ciphertext"]), "anexo: cifra da mensagem")
asig = label("direct/v1/msg-sig") + ahdr + h(am["nonce"]) + len(act).to_bytes(4, "big") + act
ok(asig == h(am["assinado_bytes"]), "anexo: bytes assinados")
ok(assinar(h(A["sign_seed"]), asig) == h(am["signature"]), "anexo: assinatura")
for f in an["deve_falhar"]:
    try:
        if "aad" in f:
            s.crypto_aead_xchacha20poly1305_ietf_decrypt(h(f["blob"])[24:], h(f["aad"]), bn, bk)
            ok(False, "anexo: deve falhar: " + f["caso"])
        else:
            ok(hashlib.sha256(h(f["blob"])).digest() != h(f["blob_sha256_esperado"]), "anexo: " + f["caso"])
    except nacl.exceptions.CryptoError:
        ok(True, "anexo: recusado: " + f["caso"])
sv = an["salvar"]
ok(sv["exif_descricao"] == f"Direct save_id={sv['save_id']} user={sv['user_id']} device={sv['device_id']} at={sv['at']}",
   "anexo: texto do EXIF")

print(f"\n{falhas} falha(s)")
sys.exit(1 if falhas else 0)
