# Conversas ocultas e senha por conversa (D12)

Ameaça: alguém com o celular **e a digital** do dono entra no app. As conversas escondidas não podem
aparecer nem abrir para essa pessoa. Tudo é local: servidor, protocolo e a outra pessoa não mudam.

## Uso

| Ação | Onde |
|------|------|
| Liberar o botão | Perfil → "Adicionar secrets" (vem desligado). Desligar só some com "Esconder conversa"; as ocultas continuam ocultas, com 7 toques, "Trocar senha" e "Mostrar conversa" |
| Esconder | folha "i" da conversa ou do grupo → "Esconder conversa"; senha própria, digitada duas vezes, mínimo de 8 caracteres |
| Mostrar as ocultas | 7 toques em "Conversas", no topo da lista, em até 3 s (relógio monotônico). Menos que isso não dá retorno |
| Abrir | pede a senha da conversa; a digital nunca é oferecida |
| Trocar senha / Mostrar conversa | folha "i", com a conversa aberta |
| Esqueci a senha da conversa | não há reset. Só "Esqueci a senha" do app (apaga tudo) e o moderador devolvendo o histórico pelo escrow |

A lista revelada volta a sumir ao sair da tela, ao bloquear e ao ir para segundo plano. A senha é
pedida de novo ao sair da conversa, bloquear, ir para segundo plano ou "Trancar conversa".

## O que muda ao esconder

- Some da lista e, no 1:1, o contato some do diretório (e da escolha de membros de grupo).
- A bolha aberta fecha como na D7; notificação e atalho são removidos; o pop-up fica proibido. A
  bolha que sobrar mostra "Conversa indisponível no pop-up", sem nome, conteúdo ou digital.
- O app não tem contador de não lidas nem busca; se ganhar, têm de excluir `db.hiddenIds`.

## Cifra no aparelho

- Cada conversa oculta tem um par X25519 próprio. A privada vai embrulhada por XChaCha20-Poly1305
  com chave derivada da senha por Argon2id (mesmos parâmetros da trava), presa ao id da conversa
  (dado associado `direct/v1/hidden:<id>`). Não depende da chave-mestra nem da digital.
- Tabela `hidden_conversations` (schema 6), no banco SQLCipher: id, pública, privada embrulhada.
  A linha é a marca de "oculta".
- Corpo (inclusive avisos locais e chaves de imagem), blob anexo e chaves de época ficam em
  `crypto_box_seal` para a pública. Quem escreve lê a marca na mesma transação da escrita.
  A prévia da lista é derivada do corpo e não existe para ocultas.
- Esconder regrava as linhas existentes numa transação; `PRAGMA secure_delete = ON` zera o que é
  sobrescrito e um `VACUUM` reescreve o arquivo em seguida.
- Mensagem que chega com a conversa fechada é guardada como o envelope recebido (cifrado pela chave
  de época, que está selada) e só é verificada e decifrada depois da senha. Época nova, por evento
  ou `epochs/mine`, é aberta com a chave do aparelho e gravada já selada.
- Aberta, a privada fica só em memória; o texto é decifrado a cada leitura e não volta ao disco.
- Senha errada: o mesmo atraso crescente da trava, contado por conversa, com os dois relógios
  (correção A3).

## Grupos

Pela D11 não há conteúdo de grupo no disco. Grupo oculto é a marca mais a senha: sem ela o app só
verifica a cadeia de membros (como num grupo trancado) e não busca chaves, nome nem mensagens.

Consequência: na lista revelada, o grupo aparece com o **nome provisório** ("Grupo Ana, Marcos…",
ou o rótulo do moderador se o grupo não tem nome cifrado), porque o nome cifrado exige buscar chave.
Sem conexão, o grupo oculto não é listado (como todo grupo).

## Limites

- **Servidor e chaves do aparelho.** As chaves privadas do aparelho continuam protegidas só pela
  chave-mestra, que a digital abre. O app não oferece caminho para reabrir uma oculta sem a senha
  dela, mas quem extrair essas chaves (ferramenta própria, app adulterado, aparelho com root) pode
  buscar no servidor os embrulhos de época e as mensagens e decifrá-los. A D12 protege contra quem
  usa o app, e protege o que está no banco; não contra quem reimplementa o cliente.
- **Força da senha.** Quem tem a chave-mestra pode copiar a privada embrulhada e testar senhas fora
  do app, sem o atraso. Só o custo do Argon2id e o tamanho da senha seguram.
- **Metadados.** Continuam no banco: que a conversa existe e está oculta, com quem, `message_id`,
  horários, tamanhos, aparelhos do contato. Os 7 toques mostram os nomes (aceito pelo usuário).
- **Contato em grupos.** O nome do contato de um 1:1 oculto continua aparecendo nos grupos em que
  ele está.
- **Memória.** Strings do Dart não podem ser zeradas; o texto decifrado some quando o coletor
  passar. Restos antigos no armazenamento flash (journal apagado, páginas realocadas) continuam
  cifrados pelo SQLCipher, e só por ele.
- **Envio pendente.** No 1:1, mensagem ainda sem confirmação quando a conversa fecha fica no banco
  (selada) e sai na próxima vez que a conversa for aberta. No grupo, é descartada (como ao trancar
  o grupo).
- **Foto salva na galeria** a partir de uma oculta fica na galeria (D8).
- **Não testado:** iOS, aparelho real, e o fechamento de bolha/notificação no Android (código nativo
  só compilado).
