# Grupos — proposta

Conversas com várias pessoas da organização, com as mesmas garantias do 1:1: cifra E2E com
escrow, trava por senha/digital, chat flutuante, imagens com rastreio de salvamento.
Decisões G1 a G4 respondidas em 25/11/2026 (§9). Implementação nas fases G-A a G-D (§10).

---

## 1. O que já existe e serve

- `conversations.kind = 'group'` e `conversation_members` já estão no banco.
- A época de conversa (`docs/protocolo.md`) não depende de ser 1:1: a chave da época é embrulhada
  para cada aparelho de cada membro e para a chave de escrow. Grupo usa o mesmo mecanismo.
- Recuperação de histórico por escrow, imagens e trava funcionam igual, por conversa.

O que falta é **quem pode mudar a lista de membros** e **como os aparelhos confiam nessa lista**.

## 2. O problema central: confiar na lista de membros

No 1:1 a lista é fixa. No grupo ela muda, e quem guarda a lista é o servidor. Um servidor
invadido poderia incluir um "membro fantasma"; os aparelhos embrulhariam a chave da época para
ele e o E2E cairia sem ninguém perceber.

**Proposta: cadeia de mudanças assinadas.**
- Toda mudança (criar, adicionar, remover, promover, sair) vira um registro
  `{grupo, hash_do_registro_anterior, tipo, alvo, autor, horário}`, assinado com o Ed25519 do
  aparelho de um admin do grupo, ou com a chave do moderador.
- A chave pública do moderador é fixada pelo QR do convite versão 2 ou, em aparelho já cadastrado,
  pelo QR de fixação ou por código (`protocolo-grupos.md` §3).
- Antes de embrulhar chave para alguém, o aparelho confere a cadeia inteira. Membro sem registro
  assinado válido não recebe chave.
- O servidor só guarda e repassa a cadeia. Ele não consegue forjar um registro.

## 3. Papéis

| Papel | Pode |
|-------|------|
| Membro | Ler, enviar, sair do grupo, abrir em pop-up. |
| Admin do grupo | Tudo do membro, mais adicionar, remover, promover a admin, mudar nome e foto, encerrar. Não se remove: sai. |
| Moderador (CLI) | Criar grupos oficiais, ver grupos e membros, remover membro, encerrar grupo. Não adiciona, promove nem renomeia. Não lê mensagens sem a chave de escrow. |

## 4. Chaves e épocas

- **Nova época quando:** entra ou sai membro; entra, sai ou é revogado um aparelho de membro.
- **Quem cria:**
  - Remoção: o admin que remove cria a época na hora, no mesmo ato. Assim quem saiu não lê a
    próxima mensagem de ninguém.
  - Mudança de aparelho: o próximo remetente, como no 1:1.
- **Custo:** cada época leva uma sealed box (~80 bytes) por aparelho de membro, mais uma para o
  escrow. 100 membros com 2 aparelhos cada dão ~16 KB por época. Tranquilo até algumas centenas
  de aparelhos.
- Acima disso o caminho certo é MLS (RFC 9420), que troca as N caixas por uma árvore. Fora do
  escopo; só vale se surgirem grupos com milhares de pessoas.
- Toda mensagem continua assinada pelo aparelho remetente, e todos verificam.

## 5. Nome, foto e descrição do grupo

- Ficam cifrados com a chave da época. O servidor e o Cloudflare não sabem que o grupo se chama
  "Diretoria".
- Na CLI o moderador vê ID, membros, admins e datas, mas não o nome.
- Grupo criado pelo moderador na CLI pode ter um **rótulo administrativo** em claro, separado do
  nome que os membros veem.

## 6. Fluxos

**Criar:** usuário escolhe pessoas no diretório e dá um nome. O app assina o registro de criação,
cria a época 1 e embrulha a chave para todos os aparelhos + escrow.

**Adicionar:** admin escolhe a pessoa. O app assina o registro e cria época nova incluindo os
aparelhos dela. O que ela vê do passado depende de G2.

**Remover ou sair:** registro assinado e época nova imediata, sem os aparelhos de quem saiu.
O que acontece no aparelho de quem saiu depende de G3.

**Aparelho novo de um membro:** igual ao 1:1. O moderador faz `escrow rewrap` e as épocas do
grupo vêm junto.

## 7. Interface

- A lista de conversas mistura 1:1 e grupos, com ícone diferente.
- Cada mensagem do grupo mostra o nome do remetente.
- Tela de informações: membros, admins, adicionar (só admin), sair.
- Chat flutuante: uma bolha por grupo, como no 1:1. Fechar a bolha tranca o grupo (D7).
- Imagens: iguais ao 1:1. Salvar registra no servidor e grava EXIF (D8).
- Mensagens de quem perdeu o acesso aparecem seladas, e o grupo só abre com internet (D11, §11).
- Fora desta proposta: confirmação de leitura, menções, enquetes, modo "só admins enviam".

## 8. Servidor e CLI

Rotas e tabelas em `protocolo-grupos.md` §10.1 e §10.2.

O WebSocket entrega cada mensagem a todos os aparelhos ativos dos membros.

CLI:

```
direct-admin group list
direct-admin group show <id>
direct-admin group create --label "<rótulo>" --admin <user_id>... [--member <user_id>...] --mod-key <arquivo>
direct-admin group remove-member <id> <user_id> --mod-key <arquivo>
direct-admin group close <id> --mod-key <arquivo>
```

Os comandos que mudam o grupo assinam o registro com a chave do moderador. Essa chave tem o
mesmo cuidado da chave de escrow: fica fora do servidor.

## 9. Decisões

| ID | Pergunta | Opções | Decisão |
|----|----------|--------|--------------|
| G1 | Quem cria grupo? | (a) qualquer usuário; (b) só o moderador pela CLI; (c) os dois | (c): usuários criam grupos comuns; o moderador cria os oficiais e pode remover membros e encerrar qualquer grupo. Decidido (25/11/2026) |
| G2 | Quem entra vê o histórico? | (a) só a partir da entrada; (b) tudo, com o admin reembrulhando as épocas antigas | (a) como padrão; o admin pode liberar o histórico ao adicionar. Decidido (25/11/2026) |
| G3 | E o aparelho de quem sai? | (a) mantém o que já tinha; (b) o app apaga o histórico do grupo ao saber da remoção | Resolvido por D11 (§11): conteúdo de grupo não fica no aparelho, então não há o que apagar |
| G4 | Tamanho máximo | 50, 100, 256 membros | 100, revisitar se precisar. Decidido (25/11/2026) |

## 10. Fases sugeridas (depois de F7 e F8)

| Fase | Entrega | Modelo | Esforço |
|------|---------|--------|---------|
| G-A Protocolo de grupos | Cadeia assinada, chave do moderador no QR, regras de época, vetores, mensagem selada e revogação pré-assinada (§11) | Opus 5.5 | high |
| G-B Servidor e CLI | Rotas, tabelas, entrega no WebSocket, comandos `group`, filtro por autor ativo, `self-revoke`, `token reactivate` | Sonnet 5.5 | high |
| G-C App | Criar, informações, adicionar/remover, mensagens com remetente, bolha de grupo, grupo só em memória, exibição selada | Sonnet 5.5 | high |
| G-D Revisão | Revisão de segurança da cadeia e das épocas | Opus 5.5 | high |

G-B e G-C podem rodar em paralelo depois da G-A.

## 11. Mensagens seladas de quem perdeu o acesso (D11)

Num grupo, a mensagem de um membro só fica legível enquanto ele estiver **ativo**: com pelo menos
um aparelho não revogado e não expirado, e com o usuário não desativado. Estar offline não conta;
quem está offline continua ativo. No 1:1 a regra não vale: o outro lado continua lendo pela cópia
local.

Exemplo. Antes:

```
Pessoa 1: mandou mensagem
Pessoa 2: mandou também
```

A pessoa 1 esquece a senha e apaga o app. Para os outros membros fica:

```
Pessoa 1: #314r59@#34929134u5%
Pessoa 2: mandou também
— Pessoa 1 perdeu o acesso —
```

O moderador restaura o acesso e a pessoa 1 cadastra o aparelho de novo:

```
Pessoa 1: mandou mensagem
Pessoa 2: mandou também
— Pessoa 1 perdeu o acesso —
— Pessoa 1 voltou ao grupo —
```

"Perdeu o acesso" e "voltou ao grupo" são diferentes de sair e entrar (§6): a pessoa continua
membro, e a cadeia de membros (§2) não muda.

### 11.1 Como funciona

- **Conteúdo de grupo não fica no celular.** Chaves de época, texto cifrado, texto aberto e
  imagens do grupo ficam só em memória. Ao abrir o grupo, o app busca no servidor. Se o app
  trancar, fechar ou o processo morrer, tudo isso some.
- **Sem internet**, o app abre só as conversas 1:1, pela cópia local. Os grupos ficam
  indisponíveis até o app conectar e autenticar.
- **O servidor faz o bloqueio.** No sync e no WebSocket, a mensagem de autor inativo vai selada:
  id, autor e horário, mais um embaralhado só para exibir. O texto cifrado real não vai, e o
  embaralhado não serve para decifrar nada.
- **Mudança no meio da sessão:** o servidor avisa pelo WebSocket (`member_access {user_id,
  active}`). O app apaga da memória as mensagens daquele autor e mostra seladas. Quando ele volta,
  o app busca de novo.
- **Imagens** de autor inativo: `GET /v1/blobs` recusa com 403 `sender_inactive`, e a miniatura
  vira cadeado.
- As linhas "perdeu o acesso" e "voltou ao grupo" vêm do histórico de status de acesso que o
  servidor guarda por usuário.
- Mensagens novas: revogar o aparelho já cria época nova (§4), então o aparelho perdido não
  recebe a chave das próximas.

### 11.2 Restaurar o acesso

1. Moderador reabre o mesmo token, com uso único e novo prazo:
   `direct-admin token reactivate <id> --ttl 24h`. Ou cria outro:
   `direct-admin token create --user <id> --ttl 24h`.
2. A pessoa cadastra o aparelho com o token.
3. `direct-admin escrow rewrap --device <novo> --key /mnt/pendrive/escrow.key` devolve as épocas,
   inclusive as dos grupos.
4. O usuário volta a ser ativo. O servidor libera de novo as mensagens dele, e os membros veem
   "voltou ao grupo".

### 11.3 Revogação pré-assinada ("Esqueci a senha")

A chave de assinatura do aparelho fica no cofre, presa à senha. Quem esqueceu a senha não consegue
assinar nada para o servidor. Por isso:

- No cadastro, o app gera uma revogação já assinada com o Ed25519 do aparelho
  (`{device_id, "revoke", horário}`) e a guarda fora do cofre, no Keystore/Keychain, sem senha.
  Aparelhos já cadastrados geram a sua no próximo desbloqueio.
- "Esqueci a senha" com internet: o app envia a revogação para `POST /v1/devices/self-revoke`, sem
  token de acesso, antes de apagar tudo. O servidor revoga na hora.
- Sem internet: o app apaga do mesmo jeito. A revogação vale quando o moderador revogar pela CLI.
- Risco aceito: quem pegar o celular consegue revogar aquele aparelho. Isso só derruba o acesso;
  não lê nada.

Vale também fora de grupos: no 1:1 o aparelho fica revogado na hora, mas nada é selado.

### 11.4 Limites

- É bloqueio de entrega, não apaga a memória de ninguém. Quem leu antes pode ter anotado ou
  fotografado a tela com outro aparelho, e um app adulterado poderia guardar cópia.
- Quem decide se um membro está ativo é o servidor. Um servidor invadido poderia selar ou liberar
  mensagens. Liberar, porém, só mostra a quem já é membro: a chave da época continua embrulhada só
  para os aparelhos dos membros e para o escrow (E2E).
- O escrow segue igual: o moderador com o pendrive reembrulha o histórico do grupo para um
  aparelho novo.

### 11.5 O que muda em cada fase

| Fase | Mudança |
|------|---------|
| G-A | Formato da mensagem selada, evento `member_access`, formato da revogação pré-assinada, vetores. |
| G-B | Filtro por autor ativo no sync, no WebSocket e em `GET /v1/blobs`; histórico de status de acesso; `POST /v1/devices/self-revoke`; `direct-admin token reactivate`. |
| G-C | Grupo só em memória; sem internet, só 1:1; exibição selada e linhas de status; revogação pré-assinada no cadastro e no "Esqueci a senha". |
