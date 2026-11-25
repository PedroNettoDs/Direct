# Segurança do Direct

O Direct é um mensageiro de uso interno, com criptografia de ponta a ponta, servidor próprio e
cadastro só por convite do moderador. Esta página diz o que ele protege, onde ficam os segredos, o
que fazer num incidente e os limites conhecidos. O detalhe está nos documentos de `docs/`.

**Situação:** v1, sem auditoria externa. A revisão de segurança de grupos, conversas ocultas e
instalador (G-D) ainda não foi feita. O app nunca foi testado em aparelho real nem compilado para iOS.

## Como avisar sobre uma falha

Não abra issue pública. Use **Security → Report a vulnerability** no GitHub (o dono do repositório
precisa ativar o aviso privado em Settings) ou fale direto com o mantenedor. Diga o que acontece,
como reproduzir e o que um atacante ganha.

## O que o Direct protege

- **Conteúdo:** mensagens e imagens são cifradas no aparelho (XChaCha20-Poly1305) e assinadas
  (Ed25519). O servidor e a Cloudflare guardam e repassam só texto cifrado.
- **Servidor autêntico:** o QR do convite fixa as chaves públicas do servidor, do escrow e do
  moderador. O app recusa um servidor com outras chaves.
- **Acesso:** só entra quem recebe convite. Cada aparelho tem chave própria e pode ser revogado.
- **Aparelho:** banco SQLCipher, senha do app com Argon2id, digital opcional, `FLAG_SECURE` contra
  print e proteção contra sobreposição. Conversas ocultas têm senha própria, nunca a digital.
- **Grupos:** a lista de membros é uma cadeia de mudanças assinadas. Mensagens de quem perdeu o
  acesso ficam seladas para todos até o moderador restaurar (D11).

Não protege, por desenho:

- **Escrow:** quem tem a chave de escrow e a senha dela lê todo o histórico. É o que permite
  recuperar as conversas num aparelho novo.
- **Sigilo futuro:** não existe. Uma chave de época vazada abre a época inteira.
- **Metadados:** o servidor vê quem fala com quem, quando e o tamanho das mensagens.
- **Fora do escopo:** aparelho com root ou jailbreak, coerção e foto da tela tirada com outro
  celular.

## Onde ficam os segredos

| Segredo | Onde fica | Quem tiver consegue |
|---------|-----------|---------------------|
| `escrow.key` + senha | pendrive, fora do servidor | ler todo o histórico |
| `moderador.key` + senha | pendrive, fora do servidor | assinar mudanças de grupo |
| `direct-release.jks` + senha | `~/.direct/` e pendrive | publicar um APK falso aceito como atualização |
| `server_sign.key` | `deploy/data/directd/` | se passar pelo servidor junto com o banco |
| `db_password` | `deploy/secrets/` | ler o banco (conteúdo cifrado, metadados em claro) |
| `cf_tunnel_token` | `deploy/secrets/` | ligar outro conector no lugar do servidor |
| `key.properties` | `app/android/` | usar a chave do APK, se tiver o `.jks` |

Nada disso vai para o git: `.gitignore` cobre `deploy/secrets/`, `deploy/data/`, `.env`,
`key.properties`, `*.jks` e `*.keystore`. O instalador recusa gravar chave privada dentro do projeto.

## Em caso de incidente

Os comandos rodam no servidor, dentro de `deploy/`, como
`docker compose exec directd /direct-admin <comando>`.

| Aconteceu | Faça |
|-----------|------|
| Celular perdido ou roubado | `device list --user <id>` e `device revoke <id>`. A cópia local fica protegida pela senha do app. |
| Pessoa saiu da organização | `user disable <id>`. Nos grupos, `group remove-member`. |
| Esqueceu a senha do app | Se estiver online, o app revoga o próprio aparelho ao apagar tudo. Depois, `token reactivate <id> --ttl 24h` ou um convite novo, e `escrow rewrap` no notebook do moderador. |
| Token do túnel vazou | Apague o túnel no painel, crie outro e rode o `setup` com o token novo (`docs/cloudflare.md`). |
| Chave do APK vazou | Gere outra chave (`docs/apk.md`). Cada celular desinstala e instala de novo, e o histórico volta pelo escrow. |
| Chave de escrow ou do moderador vazou com a senha | A v1 não troca essas chaves. É preciso instalar o servidor do zero e refazer os convites. |
| Servidor invadido | Pare os serviços e preserve `deploy/data/`. Veja `docs/ameacas.md` §3. Peça aos usuários atenção ao aviso de aparelho novo. |

## Limites conhecidos

- **Disco do servidor:** sem LUKS e sem backup periódico (D6). Disco roubado expõe metadados e a
  chave de assinatura do servidor. Disco perdido leva tudo.
- **Mensagens seladas (D11):** quem bloqueia é o servidor. Um servidor invadido ou um cliente
  modificado pode entregar a mensagem a quem já tinha a chave da época.
- **Conversas ocultas (D12):** quem extrai as chaves do aparelho (root, app adulterado) consegue
  baixar de novo o histórico do servidor e decifrá-lo (`docs/ocultas.md`).
- **Grupos:** um membro removido, junto com um servidor invadido, consegue injetar mensagem numa
  época antiga.
- **Revisão F8 com pendências:** S1 tem resto; S5, S7 e B2 estão corrigidos em parte; A4 não foi
  totalmente verificado; S9 foi aceito (`docs/revisao-seguranca.md`).
- **Sem teste real:** iOS nunca compilado. Android só em emulador e testes automáticos. O
  fechamento nativo da bolha e da notificação foi só compilado.

## Documentos

- [`docs/ameacas.md`](docs/ameacas.md): modelo de ameaças, atacante por atacante.
- [`docs/revisao-seguranca.md`](docs/revisao-seguranca.md): achados da revisão F8 e o status de cada um.
- [`docs/protocolo.md`](docs/protocolo.md) e [`docs/protocolo-grupos.md`](docs/protocolo-grupos.md): protocolo e criptografia.
- [`docs/grupos.md`](docs/grupos.md) §11: mensagens seladas (D11).
- [`docs/ocultas.md`](docs/ocultas.md): conversas ocultas (D12).
- [`deploy/README.md`](deploy/README.md), [`docs/cloudflare.md`](docs/cloudflare.md) e [`docs/apk.md`](docs/apk.md): instalação, túnel e assinatura do APK.
