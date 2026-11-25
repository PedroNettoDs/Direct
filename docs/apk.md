# Gerar e assinar o APK do Android

O APK release é assinado com uma chave sua. Sem ela, `flutter build apk --release` para com o erro
"Falta android/key.properties". O release nunca sai com a chave de debug.

> **Guarde essa chave como guarda o escrow.** O Android só instala uma atualização assinada pela
> mesma chave. Sem ela, cada celular precisa desinstalar o app. Isso apaga os dados locais, e o
> histórico só volta pelo escrow. Quem tiver a chave e a senha consegue publicar um APK falso que o
> celular aceita como atualização.

## 1. Criar a chave (uma vez só)

A chave fica fora do projeto. O `keytool` vem com o JDK.

```bash
mkdir -p ~/.direct && chmod 700 ~/.direct
keytool -genkeypair -v -keystore ~/.direct/direct-release.jks -storetype PKCS12 -keyalg RSA -keysize 4096 -validity 10000 -alias direct
```

O `keytool` pede uma senha e um nome (pode ser só "Direct"). Use 16 caracteres ou mais e uma senha
diferente das do escrow e do moderador. Com PKCS12, a senha da chave é a mesma do arquivo.

Faça uma cópia de `~/.direct/direct-release.jks` no pendrive das chaves e na segunda cópia offline.

## 2. Apontar o build para a chave

Crie o arquivo `app/android/key.properties`, só legível por você:

```bash
install -m 600 /dev/null app/android/key.properties
```

Abra o arquivo num editor e preencha, trocando `SUA_SENHA` pela senha do passo 1:

```properties
storeFile=/home/SEU_USUARIO/.direct/direct-release.jks
storePassword=SUA_SENHA
keyAlias=direct
keyPassword=SUA_SENHA
```

Escreva a senha no editor, não num comando, para ela não ir para o histórico do shell. O
`.gitignore` de `app/android/` já ignora `key.properties`, `*.jks` e `*.keystore`.

## 3. Gerar o APK

Dentro de `app/`:

```bash
flutter build apk --release --split-per-abi
```

Distribua `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`, que serve para quase todo
celular atual. Sem `--split-per-abi` sai um APK só, com todas as arquiteturas e cerca de 96 MB.

Para conferir a assinatura, compare a impressão digital do APK com a da chave:

```bash
apksigner verify --print-certs build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
keytool -list -v -keystore ~/.direct/direct-release.jks -alias direct
```

As linhas `SHA-256` têm de ser iguais. O `apksigner` fica em `~/Android/Sdk/build-tools/<versão>/`.

## 4. Instalar no celular

1. Mande o APK para o celular por cabo, pelo Drive ou por outro meio que você confie.
2. Abra o arquivo. O Android pede para permitir a instalação de apps daquela origem: permita só
   para esse app (Arquivos, Drive) e desligue depois.
3. Para atualizar, instale o APK novo por cima. Os dados ficam, desde que a chave seja a mesma.

Um APK de outra máquina, ou assinado com outra chave, não instala por cima. O Android acusa conflito
de pacote.
