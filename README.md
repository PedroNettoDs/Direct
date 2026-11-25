# Direct

Mensageiro de uso interno com criptografia de ponta a ponta. Ele tem três partes:

- `server/`: o servidor (`directd`) e a CLI do moderador (`direct-admin`), em Go;
- `app/`: o app Android, em Flutter;
- `deploy/`: a instalação com Docker Compose, atrás de um Cloudflare Tunnel.

Este README mostra como colocar o Direct no ar do zero, passo a passo: preparar o servidor,
configurar a Cloudflare, instalar, gerar o APK e cadastrar os celulares. A segurança está em
[`SECURITY.md`](SECURITY.md). O plano e as decisões estão em [`docs/PLANO.md`](docs/PLANO.md).

## Sumário

1. [Como funciona](#1-como-funciona)
2. [O que você precisa](#2-o-que-você-precisa)
3. [Preparar o servidor](#3-preparar-o-servidor)
4. [Configurar a Cloudflare](#4-configurar-a-cloudflare)
5. [Preparar o pendrive](#5-preparar-o-pendrive)
6. [Rodar o instalador](#6-rodar-o-instalador)
7. [Subir o servidor e conferir](#7-subir-o-servidor-e-conferir)
8. [Registrar a chave do moderador](#8-registrar-a-chave-do-moderador)
9. [Gerar o APK](#9-gerar-o-apk)
10. [Instalar o app nos celulares](#10-instalar-o-app-nos-celulares)
11. [Cadastrar cada pessoa](#11-cadastrar-cada-pessoa)
12. [Teste final](#12-teste-final)
13. [Conferência de segurança antes de liberar](#13-conferência-de-segurança-antes-de-liberar)
14. [Dia a dia](#14-dia-a-dia)
15. [Problemas comuns](#15-problemas-comuns)

---

## 1. Como funciona

```
celular (app Direct)
   │  HTTPS e WebSocket
   ▼
Cloudflare ── direct.seudominio.com.br
   │  túnel (o servidor abre a conexão para fora; nenhuma porta aberta)
   ▼
servidor Linux, no Docker Compose
   cloudflared ──► directd :8080 ──► postgres
                       │
                       └── deploy/data/  (banco, chave do servidor, registro de comandos)
```

- O servidor não abre porta no roteador nem no host. O `cloudflared` liga para a Cloudflare e
  recebe o tráfego por esse túnel.
- O servidor guarda só texto cifrado. As chaves que abrem as mensagens ficam nos celulares.
- Duas chaves privadas ficam **fora** do servidor, num pendrive:
  - `escrow.key`: devolve o histórico a quem troca de celular ou esquece a senha.
  - `moderador.key`: assina as mudanças de grupo feitas pelo moderador.
- Ninguém entra sem convite. O moderador gera um QR por pessoa com a `direct-admin`.

## 2. O que você precisa

**Servidor**
- Um computador Linux ligado o tempo todo (Ubuntu ou Debian, por exemplo). Para dezenas de usuários,
  2 GB de RAM e 20 GB livres bastam.
- Docker Engine e Docker Compose v2.
- O projeto num sistema de arquivos Linux (ext4, XFS ou Btrfs), por causa do `chattr +a`.
- Saída para a internet. O `cloudflared` usa a porta 7844 (UDP e TCP) para fora. Não precisa abrir
  porta de entrada.

**Cloudflare**
- Uma conta (o plano grátis basta).
- Um domínio seu já ativo na Cloudflare (nameservers apontando para ela).

**Chaves**
- Um pendrive só para as chaves, e um segundo pendrive (ou outro meio offline) para a cópia.
- Três senhas diferentes, que você vai criar: a da chave de escrow e a do moderador (16 caracteres
  ou mais cada) e a da chave do APK.

**Máquina de build do APK**
Pode ser o seu notebook ou o próprio servidor. Ela precisa de:
- Flutter 3.50 ou mais novo (Dart 3.14 ou mais novo);
- Android SDK (pelo Android Studio ou pelas command-line tools);
- JDK 17.

**Celulares**
- Android 11 ou mais novo. O app para iOS ainda não existe: precisa de Mac para compilar e nunca
  foi testado.

> **Antes de começar:** o app nunca foi testado em celular real, só em emulador e em testes
> automáticos. Faça o primeiro cadastro no seu próprio celular e use alguns dias antes de chamar as
> outras pessoas.

## 3. Preparar o servidor

### 3.1 Instalar o Docker

1. Instale o Docker Engine e o plugin Compose pelo guia oficial da sua distribuição:
   <https://docs.docker.com/engine/install/>.
2. Deixe o Docker subir sozinho no boot e libere o seu usuário para usá-lo:

   ```bash
   sudo systemctl enable --now docker
   ```
   ```bash
   sudo usermod -aG docker $USER
   ```

3. Saia e entre de novo na sessão. Depois confira:

   ```bash
   docker version
   ```
   ```bash
   docker compose version
   ```

   O segundo comando deve mostrar `Docker Compose version v2…` ou mais novo.

### 3.2 Baixar o projeto

O repositório é privado. O jeito mais simples é usar o GitHub CLI no servidor:

```bash
gh auth login
```
```bash
cd ~ && gh repo clone PedroNettoDs/Direct
```

Se preferir, use uma chave SSH de deploy (só leitura) no repositório.

Os dados vão ficar dentro dessa pasta, em `Direct/deploy/data/`. Escolha um disco com espaço e
confira o tipo do sistema de arquivos. Deve aparecer `ext4`, `xfs` ou `btrfs`:

```bash
df -T ~/Direct
```

### 3.3 Proteger o acesso ao servidor

Quem entra no servidor como root lê os metadados e a chave de assinatura do servidor
([`SECURITY.md`](SECURITY.md)). No mínimo:

- SSH só com chave, sem senha (`PasswordAuthentication no` em `/etc/ssh/sshd_config`);
- atualizações automáticas de segurança ligadas (`unattended-upgrades` no Ubuntu e no Debian);
- servidor num lugar fisicamente seguro. Por decisão do projeto, o disco não é cifrado.

## 4. Configurar a Cloudflare

O passo a passo completo, com os campos de cada tela e os erros comuns, está em
[`docs/cloudflare.md`](docs/cloudflare.md). Em resumo:

1. Escolha o endereço do servidor, com um nível só de subdomínio. Por exemplo:
   `direct.seudominio.com.br`.
2. Em **Networking → Tunnels**, crie um túnel do tipo **Cloudflared**.
3. Copie **só o token** (o texto longo que começa com `eyJ`). Guarde-o para o passo 6. **Não rode**
   o comando de instalação que a Cloudflare mostra.
4. No túnel, abra **Routes → Add route → Published application** e preencha:
   - o subdomínio e o domínio do passo 1;
   - Service URL `http://directd:8080`.
5. **Não** crie aplicação do Cloudflare Access para esse endereço.
6. Deixe o **Bot Fight Mode** e o **Under Attack Mode** desligados.

O túnel vai aparecer como inativo até o passo 7. Isso é normal.

> **O token do túnel é uma senha.** Não cole em chat, e-mail ou print. Quem tiver o token consegue
> ligar outro servidor no lugar do seu.

## 5. Preparar o pendrive

1. Espete o pendrive no servidor e descubra onde ele está:

   ```bash
   lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS
   ```

2. Se ele já estiver montado (algo como `/media/<usuário>/<nome>`), anote o caminho e pule o
   item 3.

3. Num servidor sem interface gráfica, monte à mão. Troque `sdb1` pelo nome que o `lsblk` mostrou:

   ```bash
   sudo mkdir -p /mnt/pendrive
   ```
   ```bash
   sudo mount /dev/sdb1 /mnt/pendrive
   ```

O caminho precisa existir antes de rodar o instalador. O instalador recusa caminho dentro do projeto
e avisa se o caminho estiver no mesmo disco do servidor (ou seja, se não for um pendrive).

## 6. Rodar o instalador

Todos os comandos daqui em diante, até o passo 8, rodam dentro de `deploy/`:

```bash
cd ~/Direct/deploy
```

### 6.1 Compilar as imagens

```bash
docker compose --profile setup build
```

Leva alguns minutos na primeira vez. O fim deve mostrar `Image deploy-directd Built` e
`Image deploy-setup Built`.

### 6.2 Rodar o `setup`

Troque o caminho pelo do seu pendrive:

```bash
DIRECT_PENDRIVE=/mnt/pendrive docker compose run --rm setup
```

O `setup` roda **sem rede** e pergunta, nesta ordem:

1. **Senha do banco.** Ele gera sozinho e mostra `Senha do banco gerada.`. Ela fica em
   `deploy/secrets/db_password`.
2. **`Cole o token do Cloudflare Tunnel`.** Cole o token do passo 4 e tecle Enter. O token não
   aparece na tela. Se você colar o comando inteiro, ele pede de novo só o token.
3. **`Domínio público`.** Digite o endereço do passo 4, só o nome: `direct.seudominio.com.br`, sem
   `https://`, porta ou barra. Ele vai dentro de todo QR de convite. Trocar depois obriga a refazer
   os convites.
4. **`Senha da chave escrow`**, duas vezes. Use 16 caracteres ou mais. O arquivo `escrow.key` é
   gravado no pendrive.
5. **`Senha da chave do moderador`**, duas vezes. Use uma senha **diferente** da do escrow. O arquivo
   `moderador.key` também é gravado no pendrive, e a parte pública fica em `deploy/data/moderador.pub`.
6. **`Criar um convite agora?`** Responda **`não`**. O primeiro convite é feito no passo 11, depois
   de registrar a chave do moderador.

No fim ele mostra `Instalação concluída` e o aviso `RETIRE O PENDRIVE`.

> **Guarde as duas senhas num gerenciador de senhas ou em papel, longe do pendrive.** A senha do
> escrow não tem recuperação. Sem ela, ninguém recupera o histórico de quem trocar de celular.

### 6.3 Guardar o pendrive

1. Copie `escrow.key` e `moderador.key` para o segundo pendrive (ou outro meio offline).
2. Desmonte o pendrive antes de tirar:

   ```bash
   sudo umount /mnt/pendrive
   ```

3. Guarde os dois pendrives fora do servidor, em lugares diferentes.

Você só vai precisar do pendrive de novo para restaurar o histórico de alguém (`escrow rewrap`) ou
para mexer em grupos como moderador.

### 6.4 Conferir o registro de comandos

Tudo o que a `direct-admin` faz fica registrado em `data/directd/admin.log`, que só aceita
acréscimo. Confira:

```bash
sudo lsattr data/directd/admin.log
```

Deve aparecer um `a` na coluna de atributos. Se o `setup` avisou que não conseguiu marcar, rode:

```bash
sudo chattr +a data/directd/admin.log
```

## 7. Subir o servidor e conferir

```bash
docker compose up -d
```

A primeira vez baixa as imagens `postgres:17` e `cloudflare/cloudflared`. Confira cada parte:

1. **Contêineres.** Os três devem aparecer com status `Up`, e o `postgres` com `(healthy)`:

   ```bash
   docker compose ps
   ```

2. **Servidor.** O log deve mostrar a linha `directd ouvindo`, sem erro:

   ```bash
   docker compose logs directd
   ```

3. **Túnel.** O log deve mostrar linhas `Registered tunnel connection`. No painel da Cloudflare, o
   túnel passa para **Healthy**:

   ```bash
   docker compose logs cloudflared
   ```

4. **De fora.** Rode de qualquer computador:

   ```bash
   curl https://direct.seudominio.com.br/v1/server-info
   ```

   A resposta deve ser um JSON com `server_sign_pub` e `escrow_pub`.

Os três serviços têm `restart: unless-stopped`: voltam sozinhos depois de queda de energia ou
reinício do servidor.

## 8. Registrar a chave do moderador

Faça isso **uma vez**, antes do primeiro convite:

```bash
docker compose exec directd /direct-admin moderator register --pub "$(cat data/moderador.pub)"
```

A resposta é `Chave do moderador registrada. Os próximos convites saem no formato v=2.`, seguida de
um **código de verificação**. Anote o código: é o mesmo que vai aparecer em todo convite.

Depois de registrada, a chave do moderador não pode ser trocada.

## 9. Gerar o APK

Faça isto na máquina de build.

### 9.1 Conferir as ferramentas

```bash
flutter --version
```
```bash
flutter doctor
```

O `flutter --version` deve mostrar Flutter 3.50 ou mais novo. No `flutter doctor`, a linha
**Android toolchain** precisa estar sem erro. Se faltar licença, rode `flutter doctor --android-licenses`.

### 9.2 Criar a chave de assinatura (uma vez só)

O Android só aceita atualizar o app se o APK novo for assinado pela mesma chave do anterior. O build
release se recusa a rodar sem essa chave.

O passo a passo completo está em [`docs/apk.md`](docs/apk.md). Em resumo:

```bash
mkdir -p ~/.direct && chmod 700 ~/.direct
```
```bash
keytool -genkeypair -v -keystore ~/.direct/direct-release.jks -storetype PKCS12 -keyalg RSA -keysize 4096 -validity 10000 -alias direct
```

Depois, na raiz do projeto, crie `app/android/key.properties` com permissão 600:

```bash
cd ~/Direct && install -m 600 /dev/null app/android/key.properties
```

Preencha o arquivo num editor (não num comando, para a senha não ir para o histórico do shell):

```properties
storeFile=/home/SEU_USUARIO/.direct/direct-release.jks
storePassword=SUA_SENHA
keyAlias=direct
keyPassword=SUA_SENHA
```

Por fim, copie `~/.direct/direct-release.jks` para os dois pendrives das chaves.

> **Perder essa chave obriga todo mundo a desinstalar o app**, e o histórico só volta pelo escrow.
> Quem tiver a chave e a senha consegue fazer um APK falso que o celular aceita como atualização.

### 9.3 Compilar

```bash
cd ~/Direct/app
```
```bash
flutter pub get
```
```bash
flutter build apk --release --split-per-abi
```

Leva alguns minutos. O arquivo para distribuir é
`build/app/outputs/flutter-apk/app-arm64-v8a-release.apk` (cerca de 36 MB). Ele serve para quase todo
celular atual. Celular muito antigo, de 32 bits, usa o `app-armeabi-v7a-release.apk`.

Para conferir a assinatura:

```bash
apksigner verify --print-certs build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

O `apksigner` fica em `~/Android/Sdk/build-tools/<versão>/`. O nome do certificado (`DN`) deve ser
o que você digitou no `keytool`, **não** `Android Debug`.

## 10. Instalar o app nos celulares

1. Passe o APK para o celular por cabo USB, Google Drive ou outro meio que você confie. Não use grupo
   público nem link aberto.
2. No celular, toque no arquivo.
3. O Android pede para permitir a instalação de apps daquela origem (Arquivos, Drive). Permita só
   para esse app.
4. Toque em **Instalar**.
5. Depois de instalar, volte em **Configurações → Apps → acesso especial → Instalar apps
   desconhecidos** e desligue a permissão. O nome do menu muda um pouco entre fabricantes.

Para atualizar o app depois, instale o APK novo por cima. Os dados ficam, desde que a chave seja a
mesma.

## 11. Cadastrar cada pessoa

Cada pessoa precisa de um convite próprio. O convite é de **uso único**: quem usar primeiro vira
aquele usuário. Por isso, entregue pessoalmente.

### 11.1 Gerar o convite (no servidor)

```bash
cd ~/Direct/deploy
```
```bash
docker compose exec -e DIRECT_ADMIN_OPERATOR=seu-nome directd /direct-admin token create --new-user "João - Financeiro"
```

- O rótulo (`"João - Financeiro"`) só o moderador vê. A pessoa escolhe o próprio nome no app.
- `DIRECT_ADMIN_OPERATOR` diz no registro de comandos quem rodou o comando.
- O convite vale 24 h (`--ttl`, no máximo `7d`).
- O aparelho cadastrado vale 180 dias (`--device-ttl`). Para um prazo maior, use, por exemplo,
  `--device-ttl 365d`. Vencido o prazo, a pessoa precisa de convite novo (passo 14.4).

A saída mostra:
- o QR, desenhado no terminal;
- o mesmo convite em texto (`direct://…`);
- um bloco **Entrada manual** com domínio, token e o código de verificação.

Se o QR sair torto, aumente a janela do terminal ou diminua a fonte.

### 11.2 Cadastrar no celular

1. Abra o app e toque em **Ler QR do convite**. Aponte para o QR do terminal.
   - Sem câmera, toque em **Digitar domínio e token** e copie os três campos da Entrada manual. O
     **Código de verificação (20 dígitos)** precisa bater com o do terminal.
2. Na tela **Criar senha do app**, confira se o servidor mostrado é o seu domínio.
3. Crie a senha do app (8 caracteres ou mais), digite duas vezes e toque em **Cadastrar este
   aparelho**.
4. Em **Seu perfil**, preencha o nome que os outros vão ver e toque em **Salvar**.
5. Ainda no perfil, deve aparecer **Grupos ativados**. Se aparecer **Ativar grupos**, o convite foi
   gerado antes do passo 8. Nesse caso, rode `da moderator qr` (passo 14) e, no perfil, toque em
   **Ler QR**.
6. Se quiser, ligue **Desbloquear com digital**. A senha continua valendo como reserva.

> **Esquecer a senha do app apaga o que está no celular.** O histórico volta só com o moderador
> (passo 14.4).

## 12. Teste final

Faça com duas pessoas, de preferência em redes diferentes (uma no Wi-Fi e outra no 4G):

1. A pessoa A encontra a B na lista de contatos e manda uma mensagem. A B recebe na hora.
2. A B responde com uma foto. A A vê a foto.
3. Uma das duas cria um grupo com a outra, e as duas trocam mensagens nele.
4. A A fecha o app e abre de novo. O app pede a senha (ou a digital).
5. Tente tirar um print dentro do app. O Android deve bloquear.

Se algo falhar, veja os logs no servidor:

```bash
docker compose logs --tail 100 directd
```

## 13. Conferência de segurança antes de liberar

- [ ] Os dois pendrives estão fora do servidor, em lugares diferentes, e as senhas guardadas à parte.
- [ ] `sudo lsattr data/directd/admin.log` mostra `a`.
- [ ] Na Cloudflare: sem Access no endereço, Bot Fight Mode e Under Attack Mode desligados.
- [ ] O token do túnel não está em nenhum chat, e-mail ou print.
- [ ] A chave do APK está nos dois pendrives, e o APK distribuído não é assinado com `Android Debug`.
- [ ] O SSH do servidor só aceita chave.
- [ ] Você leu os limites em [`SECURITY.md`](SECURITY.md). Os principais: o disco do servidor não é
      cifrado, não há backup automático, e quem tem o escrow com a senha lê todo o histórico.

## 14. Dia a dia

Os comandos rodam no servidor, dentro de `~/Direct/deploy`. Para encurtar, crie um atalho na sessão:

```bash
alias da='docker compose exec -e DIRECT_ADMIN_OPERATOR=seu-nome directd /direct-admin'
```

Com o atalho, `da user list` é o mesmo que o comando completo. A lista completa de comandos está em
[`docs/PLANO.md`](docs/PLANO.md) §10.

### 14.1 Parar, subir e ver logs

```bash
docker compose stop
```
```bash
docker compose up -d
```
```bash
docker compose logs -f directd
```

O `docker compose down` apaga os contêineres, mas não os dados, que continuam em `data/`.

### 14.2 Atualizar o servidor

```bash
cd ~/Direct && git pull
```
```bash
cd deploy && docker compose --profile setup build && docker compose up -d
```

### 14.3 Pessoas e aparelhos

| Situação | Comando |
|----------|---------|
| Ver usuários | `da user list` |
| Ver os aparelhos de alguém | `da device list --user <id>` |
| Celular perdido ou roubado | `da device revoke <id_do_aparelho>` |
| Pessoa saiu da organização | `da user disable <id>` (revoga todos os aparelhos e convites pendentes) |
| Ver convites | `da token list` |
| Cancelar um convite não usado | `da token revoke <id>` |

### 14.4 Celular novo, senha esquecida ou aparelho vencido

1. Dê à pessoa um convite para o **mesmo usuário**:
   - `da token create --user <id_do_usuário>`, ou
   - `da token reactivate <id_do_convite> --ttl 24h`, que reabre o convite antigo sem reimprimir o QR.
     Serve para quem esqueceu a senha e ainda tem o QR.
2. A pessoa se cadastra de novo (passo 11.2).
3. Para devolver o histórico, rode o `escrow rewrap` no **notebook do moderador**, com o pendrive.
   Ele nunca roda no servidor, para a chave e a senha do escrow não passarem por lá. O procedimento,
   com túnel SSH até o banco e duas confirmações, está em [`server/README.md`](server/README.md).

Nos grupos, as mensagens de quem perdeu o acesso ficam seladas para todos até esse passo
([`docs/grupos.md`](docs/grupos.md) §11).

### 14.5 Atualizar o app

1. Gere o APK de novo (passo 9.3), com a **mesma** chave.
2. Aumente `version` em `app/pubspec.yaml` antes de compilar. Por exemplo, de `1.0.0+1` para `1.0.1+2`.
   O número depois do `+` precisa subir a cada versão.
3. Distribua como no passo 10, instalando por cima.

### 14.6 Cópia dos dados

Não há backup automático, por decisão do projeto. Para fazer uma cópia à mão:

```bash
docker compose stop
```
```bash
sudo cp -a data /caminho/do/disco-externo/direct-data-$(date +%F)
```
```bash
docker compose up -d
```

A cópia contém a chave de assinatura do servidor e os metadados em claro. Guarde-a como guarda os
pendrives.

## 15. Problemas comuns

| Sintoma | O que fazer |
|---------|-------------|
| `erro: o banco está em uso. Pare os serviços antes: docker compose stop` | O `setup` não roda com o servidor no ar. Rode `docker compose stop` e repita. |
| `erro: falta o pendrive` | Falta `DIRECT_PENDRIVE=…` antes do comando, ou o caminho não existe. |
| `… já existe; não sobrescrevo` | O pendrive já tem a chave. Use outro pendrive ou mova o arquivo. |
| `… está dentro da pasta do projeto` | O caminho do pendrive aponta para dentro do projeto. Monte o pendrive fora dele. |
| `chave do moderador não registrada` | Rode o passo 8. |
| Erro **1033** ou **502** ao abrir o endereço | Veja [`docs/cloudflare.md`](docs/cloudflare.md) §5. |
| O app não conecta, mas o `curl` funciona | O domínio do convite é diferente do endereço publicado. Corrija com o `setup` e gere outro convite. |
| `Falta android/key.properties` no build | Faça o passo 9.2. |
| O celular diz que o app está em conflito ao atualizar | O APK foi assinado com outra chave. Use a chave original. |
| Imagem não envia | O limite é 10 MB depois de cifrada. |

Mais detalhes:
- instalação: [`deploy/README.md`](deploy/README.md);
- Cloudflare: [`docs/cloudflare.md`](docs/cloudflare.md);
- APK: [`docs/apk.md`](docs/apk.md);
- CLI e escrow: [`server/README.md`](server/README.md).
