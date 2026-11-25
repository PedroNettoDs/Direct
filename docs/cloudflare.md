# Cloudflare para o Direct

Este guia cobre o que fazer no painel da Cloudflare para o app alcançar o servidor. A instalação do
servidor está em `deploy/README.md`.

Caminho do tráfego: app → `https://direct.seudominio.com.br` → Cloudflare → túnel → contêiner
`cloudflared` → `directd:8080`. O servidor não abre nenhuma porta no roteador nem no host.

Os nomes dos menus foram conferidos em novembro de 2026. A Cloudflare muda o painel com frequência,
então procure pelo nome mais próximo se algum não bater.

## 0. Antes de começar

- Tenha uma conta na Cloudflare com o domínio adicionado e os nameservers do registro (Registro.br,
  por exemplo) apontando para os da Cloudflare. O domínio deve aparecer como **Active**.
- Se o domínio estiver em configuração parcial (CNAME), o registro DNS do passo 2 não é criado
  sozinho. Crie-o no seu provedor de DNS.
- Escolha o endereço do servidor com **um nível só** de subdomínio, por exemplo
  `direct.seudominio.com.br`. Um endereço como `direct.chat.seudominio.com.br` exige certificado
  avançado, que é pago.

## 1. Criar o túnel e copiar o token

1. No painel, abra **Networking → Tunnels**. No painel Zero Trust o caminho é **Networks →
   Connectors → Cloudflare Tunnels**.
2. Clique em **Create a tunnel** e escolha o tipo **Cloudflared**. Dê um nome, por exemplo `direct`.
3. A tela seguinte mostra comandos de instalação. **Não rode nenhum deles.** O conector já é o
   contêiner `cloudflared` do `docker compose`.
4. Copie **só o token**: o texto longo depois de `--token`, que começa com `eyJ`.
5. Cole o token quando o `setup` pedir (`deploy/README.md`, passo 4). Ele fica em
   `deploy/secrets/cf_tunnel_token`. Se já houver um token antigo gravado, responda `sim` quando o
   `setup` perguntar se deve substituir.

> **O token é a senha do túnel.** Quem tiver o token consegue ligar outro conector no lugar do seu
> servidor. Não cole o token em chat, e-mail, print ou no git. Se ele vazar, apague o túnel no painel,
> crie outro e rode o `setup` de novo com o token novo.

## 2. Publicar o endereço do servidor

1. Abra o túnel criado, aba **Routes**, e clique em **Add route → Published application**.
2. Preencha assim:

   | Campo | Valor |
   |-------|-------|
   | Subdomain | `direct` (ou o nome que escolher) |
   | Domain | seu domínio |
   | Path | deixe vazio |
   | Service URL | `http://directd:8080` |

   No painel antigo os campos são **Public Hostname**, **Type** `HTTP` e **URL** `directd:8080`.
3. Salve. Com o domínio em configuração completa, a Cloudflare cria o registro DNS (CNAME para o
   túnel) sozinha.
4. **Não crie uma aplicação do Cloudflare Access** para esse endereço. O app não passa por login de
   navegador, e o Access bloquearia todas as chamadas. A proteção é o próprio protocolo do Direct:
   convite, chave do aparelho e assinatura do servidor.
5. Use exatamente esse endereço quando o `setup` pedir o domínio (`DIRECT_PUBLIC_HOST`): só o nome,
   em minúsculas, sem `https://` e sem porta. Ele vai dentro do QR do convite. Trocar o endereço
   depois obriga a refazer os convites.

## 3. Ajustes do domínio

Todos no painel do domínio.

| Onde | O que fazer | Por quê |
|------|-------------|---------|
| **SSL/TLS → Edge Certificates** | **Always Use HTTPS** ligado, **Minimum TLS Version** 1.2, **TLS 1.3** ligado | O app só aceita HTTPS. |
| **Network** | **WebSockets** ligado (vem ligado) | As mensagens chegam por `/v1/ws`. |
| **Security → Settings** (ou **Bots**) | **Bot Fight Mode** desligado | Ele desafia clientes que não são navegador, como o app, e não deixa abrir exceção no plano grátis. |
| **Security → Settings** | **Under Attack Mode** nunca ligado | Ele exige JavaScript de navegador, e o app para de funcionar. |
| **Caching** | Não crie regra **Cache Everything** para esse endereço | As respostas são por usuário. Sem regra, a Cloudflare não guarda as rotas do Direct. |

### Limite de tentativas (opcional)

O `directd` já limita as requisições por IP, usando o IP real que vem do `cloudflared`. Para
segurar o excesso antes de chegar ao servidor, crie uma regra na Cloudflare:

1. Abra **Security → WAF → Rate limiting rules** e clique em **Create rule**.
2. Na expressão, use o campo **URI Path** com `starts with` `/v1/enroll` **ou** `starts with`
   `/v1/auth/`.
3. Conte as requisições **por IP**: 20 a cada 10 segundos.
4. Defina a ação **Block** por 10 segundos.

O plano grátis permite uma regra e esses períodos curtos. Não aplique a regra ao endereço todo:
`/v1/ws` e `/v1/blobs` fazem muitas chamadas legítimas.

## 4. Conferir

Com o servidor no ar (`docker compose up -d`, dentro de `deploy/`):

1. Rode `docker compose logs cloudflared`. O log deve mostrar linhas `Registered tunnel connection`
   (normalmente quatro).
2. No painel, o túnel deve aparecer como **Healthy**.
3. Rode `curl https://direct.seudominio.com.br/v1/server-info`. A resposta deve ser um JSON com
   `server_sign_pub` e `escrow_pub`.
4. No celular, leia o QR de um convite e confira o código de verificação mostrado pelo
   `direct-admin`.

## 5. Problemas comuns

| Sintoma | Causa provável | O que fazer |
|---------|----------------|-------------|
| Erro **1033** no navegador ou no `curl` | Túnel sem conector | `docker compose logs cloudflared`. Confira o token, ou rode o `setup` de novo para substituí-lo. |
| **502 Bad Gateway** | `directd` parado ou Service URL errada | `docker compose ps` e `docker compose logs directd`. A Service URL é `http://directd:8080`. |
| App mostra erro de rede, e o `curl` devolve uma página HTML de desafio | Bot Fight Mode, Under Attack ou regra do WAF | Desligue esses recursos (passo 3) e veja **Security → Events**. |
| O endereço não resolve | Registro DNS ausente ou domínio em configuração parcial | Em **DNS → Records**, confira o CNAME do subdomínio para `<id-do-túnel>.cfargotunnel.com`, com proxy ligado (nuvem laranja). |
| O app não conecta depois de ler o convite, mas o `curl` funciona | `DIRECT_PUBLIC_HOST` diferente do endereço publicado (o QR leva esse endereço) | Corrija em `deploy/.env` (ou rode o `setup`), suba de novo e gere outro convite. |
| Imagem não envia | Arquivo maior que 10 MB depois de cifrado | Limite do `directd`. O limite da Cloudflare no plano grátis (100 MB) não interfere. |
