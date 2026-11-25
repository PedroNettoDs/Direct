# Modelo de ameaças — Direct v1

Quem pode atacar, o que consegue, o que impede e o que sobra. Referências `§n` apontam para
`docs/protocolo.md`.

## 0. O que se protege e em quem se confia

**Ativos:** conteúdo das mensagens; autenticidade (quem enviou); histórico recuperável em
aparelho novo; acesso só para quem o moderador autorizou.

**Confiança por desenho (D5 = A):** quem tem a chave de escrow **e** a senha dela lê todo o
histórico. Isso é o requisito "aparelho novo recebe as mensagens anteriores", não uma falha.
Não há sigilo futuro (forward secrecy): chave de época vazada abre a época inteira.

**Fora do escopo:** sistema operacional do aparelho comprometido (root/jailbreak), coerção do
usuário, o que um destinatário faz com o que leu (fotografar a tela com outro celular, copiar à mão).

## 1. Resumo

| Atacante | Lê conteúdo? | Forja mensagem? | Principal defesa | Risco que sobra |
|----------|--------------|-----------------|------------------|-----------------|
| Cloudflare | Não | Não | Chaves fixadas no QR, assinaturas de app | Metadados; bloquear ou atrasar |
| Invasor do servidor | Passado: não. Futuro: sim, com aparelho fantasma | Só pelo fantasma | Aviso de aparelho novo (§7.3); escrow offline; cadeia assinada em grupos | Fantasma se ninguém der atenção ao aviso; fantasma de admin assina registros de grupo |
| Aparelho perdido | Só se souber a senha do app | Até ser revogado | Trava Argon2id + Keystore/Keychain; revogação | Cópia local num aparelho que nunca mais conecta |
| Moderador | Sim (escrow) | Sim, com aparelho fantasma | Governança; aviso de aparelho novo | Confiança necessária |
| Outro usuário | Só conversas dele | Não | Assinatura + AAD com remetente | Print no iOS; repassar conteúdo |
| Admin de grupo | O grupo (e o histórico que liberar) | Não | Registros assinados e visíveis a todos | Pode adicionar um cúmplice da organização |
| App malicioso no aparelho | Depende da permissão | Não | `FLAG_SECURE`, sobreposições, teclado | Acessibilidade e teclado no Android |

## 2. Cloudflare (ou quem o controle: funcionário, ordem judicial, invasão)

O Cloudflare termina o TLS. Vê e pode alterar tudo o que passa entre app e `directd`: requisições,
respostas e quadros do WebSocket.

**Consegue:**
- Metadados: IP, horário, quem fala com quem (`conversation_id`, `sender_device_id`), frequência,
  tamanho em blocos de 256 bytes, modelo e versão do aparelho no cadastro, nomes e status do
  diretório.
- Usar um token de acesso por até 15 min: baixar texto cifrado (que já viu), mudar nome e status
  do perfil, criar conversa.
- Bloquear, atrasar, reordenar ou repetir mensagens e eventos.
- Com o token, registrar salvamentos falsos de foto em nome do usuário (§18.6), sujando a auditoria.

**Não consegue, e por quê:**
- Ler conteúdo: só passa texto cifrado; chaves de época vão seladas (§9.4).
- Cadastrar aparelho dele com o convite de outra pessoa: a semente do convite não sai do QR; o app
  só envia assinaturas sobre as próprias chaves (§4.1, §5.2). Repetir a requisição cadastra o
  aparelho legítimo (idempotente).
- Trocar chaves no diretório ou no cadastro: certificados assinados pela chave do servidor fixada
  no QR (§5.3, §7.1).
- Trocar a chave de escrow: fixada no QR e dentro da declaração de época (§9.3).
- Trocar um embrulho por chave que ele conhece: compromisso assinado pelo criador (§9.2, §9.8).
- Forjar mensagem ou época: exigem a chave Ed25519 do aparelho.
- Fazer o app apagar os dados com resposta falsa de revogação: a prova é assinada pelo servidor e
  presa ao desafio do momento (§6.4).
- Mudar o nome de um usuário para o de outro: `admin_label` está no certificado (§5.3).
- Mensagem repetida: o app descarta `message_id` já visto (§10.7).

**Sobra:** metadados; negar serviço; mudar `display_name`/`status` (não assinados; o app mostra
`admin_label` como nome principal). Entrada manual sem QR depende de o usuário digitar o código
de verificação certo (§4.3).

## 3. Invasor do servidor (root no host, banco, arquivo da chave de assinatura)

**Consegue:**
- Tudo o que o Cloudflare consegue, e também alterar o `directd` e o banco.
- **Aparelho fantasma:** criar aparelho para qualquer usuário e assinar o certificado com a chave
  do servidor. Daí em diante, quem enviar para esse usuário cria época incluindo o fantasma.
  O invasor lê as mensagens **novas** dessas conversas e pode enviar como aquele usuário.
- Revogar ou desativar aparelhos e usuários; esconder mensagens.
- Capturar `escrow_sk` se o `rewrap` rodar no servidor enquanto ele está lá.

**Não consegue:**
- Ler histórico: as épocas antigas só abrem com a chave de escrow, que está offline, ou com as
  chaves dos aparelhos.
- Forjar mensagem de aparelho existente.
- Usar convites pendentes: o banco só tem `invite_pub` (§4.1). O mesmo vale para quem rouba o backup.

**Em grupos** (detalhes em `protocolo-grupos.md` §12):
- Não forja membro: a lista confiável é a cadeia assinada. Fantasma de **admin**, porém, assina
  registros como o admin (adicionar, liberar histórico).
- Pode esconder o fim da cadeia de quem nunca o viu; a âncora local pega o retrocesso.
- Decide quem está ativo: pode selar ou liberar mensagens e forjar linhas de acesso. Não lê nada.
- Não troca a chave do moderador já fixada. Reembrulho só com o que a cadeia permite.

**Mitigação:**
- Aviso local "<pessoa> conectou um aparelho novo" em toda conversa com ela (§7.3). Combinar na
  organização: aviso inesperado = perguntar à pessoa por outro canal.
- Rodar `escrow rewrap` no notebook do moderador, falando com o banco por túnel SSH (PLANO 5.2).
- `directd` sem porta publicada, só via `cloudflared` (PLANO 4). Volume LUKS protege disco
  desligado ou descartado, não servidor ligado.
- Logs sem conteúdo e sem tokens.

**Sobra:** fantasma lido por quem ignora o aviso. Uma defesa mais forte (certificado assinado por
chave offline do moderador) exigiria o pendrive a cada cadastro; ficou fora da v1.

## 4. Aparelho perdido ou roubado

**Aparelho bloqueado, app bloqueado (caso comum):**
- O banco local é SQLCipher; a chave-mestra está embrulhada por Argon2id da senha do app e pelo
  Keystore/Keychain (PLANO 7). Sem a senha, nada abre. Atraso crescente entre tentativas.
- Extrair o armazenamento exige desbloquear o sistema ou perícia forense; mesmo assim a força bruta
  offline da senha do app passa por Argon2id e pela chave do Keystore/Keychain, que fica no
  hardware quando há.

**Ladrão com a senha do app (ou app aberto na mão dele):**
- Lê o histórico local e envia como o dono até a revogação.

**Mitigação:**
- Moderador revoga (`direct-admin device revoke`, fluxo 6.4). O servidor corta na hora: tokens
  apagados, WebSocket fechado com 4003 (§12).
- O próximo envio em cada conversa cria época sem o aparelho (§10.6, passo 4): ele não lê nada novo
  nem pelo servidor.
- Se o app revogado se conectar, recebe a prova de revogação e apaga tudo (§6.4, §12).
- Vencimento automático (`device_ttl`) limita aparelho esquecido.

**Sobra:** aparelho que nunca mais se conecta mantém o histórico local, protegido só pela senha do
app. Recomendação à organização: senha do app longa, revogação imediata ao perceber a perda.

## 5. Moderador

**Consegue (por desenho):**
- Ler todo o histórico com a chave de escrow e a senha dela.
- Criar convite para qualquer usuário (`token create --user`) e cadastrar aparelho em nome dele:
  passa a ler e enviar como essa pessoa.
- Revogar, desativar, ver metadados no banco.

- Com a chave do moderador: criar grupos oficiais, remover membros e encerrar grupos. Não adiciona
  nem promove em grupo existente, nem libera histórico. A chave roubada, sozinha, não faz nada: os
  registros precisam ser gravados no banco.

**Mitigação:**
- O aparelho extra dispara o aviso de aparelho novo (§7.3) para os contatos.
- Governança da chave de escrow: senha com uma pessoa, pendrive com outra; duas cópias offline em
  lugares diferentes (PLANO 5.2).
- Registro de cada comando do `direct-admin` (quem, quando, alvo) em arquivo só de acréscimo fora
  do banco (a F3 implementa).

**Sobra:** a organização precisa confiar no moderador. Os usuários devem saber disso.

## 6. Outro usuário (com aparelho legítimo)

**Consegue:**
- Ler as conversas de que participa, tirar print (no iOS não há bloqueio, PLANO 8), repassar.
- Escolher `display_name` igual ao de outra pessoa.
- Como criador de época, mandar embrulho de escrow inválido: aquela época não volta por `rewrap`.
- Enviar lixo ou volume alto.
- Admin de grupo: adicionar qualquer pessoa (até 100), liberar o histórico que tem, remover,
  encerrar, renomear. Tudo fica assinado e visível a todos.
- Quem saiu ou foi removido de um grupo guarda só o que já leu: nada do grupo fica no aparelho.
- Quem pega o aparelho de alguém pode enviar a revogação pré-assinada: só derruba o acesso.

**Não consegue:**
- Ler conversa de que não participa (não recebe embrulho; o servidor confere membros).
- Assinar como outro aparelho, nem reassinar mensagem alheia como sua: `sender_device_id` está no
  AAD (§10.3).
- Mover mensagem para outra conversa ou época: `conversation_id` e `epoch` estão no AAD e na
  assinatura.
- Dar chaves diferentes a destinatários diferentes: o compromisso fixa uma chave só (§9.2).

**Mitigação:** `admin_label` assinado como nome principal (§7.1); limite de taxa (§14); o `rewrap`
lista as épocas com falha (§13.3), e o moderador sabe de quem é.

**Imagens (protocolo 18):** o servidor guarda só blob cifrado e sabe apenas que `(conversa, seq)` foi
salvo na galeria. Quem salva sem o app legítimo (print, câmera apontada para a tela) não deixa
registro; o EXIF cobre só o arquivo original salvo pelo app.

## 7. App malicioso no mesmo aparelho

**Android:**
| Ameaça | Mitigação | Sobra |
|--------|-----------|-------|
| Captura de tela/gravação (MediaProjection) | `FLAG_SECURE` em todas as janelas, inclusive a bolha (PLANO 8, 9) | — |
| Sobreposição e tapjacking | `setHideOverlayWindows(true)` (12+); `filterTouchesWhenObscured` | Android 11 sem esconder sobreposição |
| Serviço de acessibilidade lendo a tela | `accessibilityDataSensitive` nas views de conteúdo (Android 14+) | Android 11–13; usuário que concede acessibilidade a malware |
| Teclado de terceiros registrando digitação | `IME_FLAG_NO_PERSONALIZED_LEARNING` nos campos | Teclado malicioso vê o que é digitado |
| Área de transferência | O app não copia nada automaticamente nem tem botão de copiar | Texto que o usuário copiar fica lá; o app não limpa |
| Notificação da bolha mostrando texto | Notificação da bolha sem conteúdo de mensagem (F7) | — |
| Ler arquivos do app | Sandbox do sistema; SQLCipher; chaves no Keystore | Root (fora do escopo) |

**iOS:**
| Ameaça | Mitigação | Sobra |
|--------|-----------|-------|
| Print | Aviso após `userDidTakeScreenshotNotification` | **Não há bloqueio** |
| Gravação/espelhamento | Esconder conteúdo com `UIScreen.isCaptured` | — |
| Miniatura no seletor de apps | Cobrir a tela ao ir para segundo plano | — |
| Teclado de terceiros | Recusar teclados customizados (`application(_:shouldAllowExtensionPointIdentifier:)` devolvendo `false` para `.keyboard`) | — |
| Keychain de instalação anterior | Apagar Keychain no primeiro início (PLANO 7) | — |

## 8. Outros

| Atacante | Consegue | Defesa |
|----------|----------|--------|
| Rede entre usuário e Cloudflare (Wi-Fi hostil) | Nada além de IP e horário | TLS validado pelo sistema; chaves fixadas mesmo se o TLS falhar |
| Ladrão do backup (`pg_dump`) | Se quebrar o `age`: o mesmo que o invasor do servidor lendo o banco, sem a chave de assinatura | Backup cifrado com `age`; banco não guarda segredos úteis (`invite_pub`, hashes de token, texto cifrado) |
| Quem rouba o pendrive do escrow | Força bruta offline da senha | Argon2id 256 MiB, t=3; senha de 16+ caracteres; pendrive guardado com controle físico |
| Perda das duas cópias do escrow | — (não é atacante) | Ninguém recupera histórico de aparelho novo; mensagens novas seguem funcionando |
| QR fotografado por terceiro antes do uso | Cadastrar o próprio aparelho no lugar do usuário | Convite de uso único e prazo curto (24 h); usuário que recebe "convite inválido" avisa o moderador, que revoga o aparelho intruso |

## 9. Decisões que este modelo impõe às fases

- **F2:** todas as conferências do servidor em §5.4, §6.2, §9.6, §10.6; logs sem conteúdo nem tokens.
- **F3:** `rewrap` com conferência de compromisso e assinatura (§13.3); registro de comandos (5).
- **F4:** trava local com Argon2id + Keystore/Keychain; apagar tudo com prova de revogação (§6.4).
- **F5:** validações de §7.1, §9.8, §10.7; aviso de aparelho novo (§7.3); `admin_label` como nome.
- **F6:** tabelas da seção 7, incluindo teclados customizados no iOS e `accessibilityDataSensitive`.
- **F7:** notificação da bolha sem conteúdo.
- **F8:** revisar cada linha "Não consegue" deste documento contra o código.
- **G-B:** cadeia verificada no servidor; seladas e `sender_inactive`; reembrulho de grupo só com
  `pode_reembrulhar`.
- **G-C:** cadeia verificada e âncora local; aviso de aparelho novo (A1) antes de liberar grupos;
  grupo só em memória.
- **G-D:** revisar `protocolo-grupos.md` §12 contra o código.
