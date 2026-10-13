# Anki para iOS

Um app iOS (iPhone e iPad) em SwiftUI construído sobre o mesmo núcleo em Rust
(`rslib/`) usado pelo Anki desktop. O agendamento (incluindo FSRS), a
renderização dos cartões e a sincronização com o AnkiWeb são feitos pelo
código compartilhado, então o app é compatível com as coleções do desktop e
do AnkiWeb.

> Este não é o AnkiMobile oficial. O AnkiMobile é o app oficial para iOS, e
> sua venda financia o desenvolvimento do Anki.

## Recursos

- Login no AnkiWeb (ou em um servidor de sincronização próprio)
- Sincronização normal, completa (upload/download) e de mídia; resolução de
  conflitos; sincronização automática ao abrir e ao sair do app
- Lista de baralhos com subbaralhos e contagens novos/aprendendo/revisão
- Estudo com os botões De novo/Difícil/Bom/Fácil e os intervalos previstos
- Cartões com o HTML/CSS dos modelos, imagens da pasta de mídia, áudio
  (`[sound:...]`), TTS, modo escuro, cloze e "digite a resposta"
- MathJax (requer internet)
- Desfazer, ocultar e suspender cartões
- Adicionar notas em qualquer tipo de nota e baralho
- Interface em inglês e português (Brasil)

Ainda não incluídos: navegador de cartões, editor de notas existentes,
estatísticas, opções de baralho e importação de .apkg. Essas
funções podem ser usadas no desktop ou no AnkiWeb e chegam pelo sync.

## Arquitetura

```
ios/
├── bridge/          crate Rust (staticlib) com uma API C que recebe/retorna JSON
│   ├── src/commands.rs   comandos: open, login, sync, fullSync, deckTree, nextCard, ...
│   ├── include/          anki_bridge.h + module.modulemap (módulo Swift "AnkiBridge")
│   └── tests/            testes do fluxo de estudo (rodam no Linux/macOS)
├── AnkiApp/         app SwiftUI
│   ├── Backend/     wrapper assíncrono da ponte, modelos, Keychain
│   ├── Study/       tela de estudo, WebView dos cartões, áudio
│   └── Views/       baralhos, login, adicionar nota, ajustes
├── build-rust.sh    compila o núcleo para iOS e gera build/AnkiBridge.xcframework
└── project.yml      especificação XcodeGen do projeto Xcode
```

O Swift chama `anki_bridge_command(bridge, "{\"cmd\": \"nextCard\"}")` e recebe
`{"ok": ...}` ou `{"error": {"kind": ..., "message": ...}}`. A senha do AnkiWeb
nunca é guardada: o login devolve uma chave (hkey), armazenada no Keychain.

A coleção fica em `Documentos/collection.anki2` (mídia em
`collection.media/`), visível no app Arquivos.

## Compilar

Requisitos: macOS com Xcode 15+, [rustup](https://rustup.rs) e
[XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
ios/build-rust.sh          # compila o núcleo Rust (alguns minutos na 1ª vez)
cd ios && xcodegen generate
open AnkiiOS.xcodeproj
```

No Xcode, escolha seu time em *Signing & Capabilities* (troque o Bundle
Identifier se necessário) e rode no simulador ou no seu iPhone.

### Sem Mac: build pelo GitHub Actions

O workflow `.github/workflows/ios.yml` compila o app em um runner macOS a cada
push que altere `ios/` e publica um artefato `Anki-iOS-unsigned` com um
`.ipa` sem assinatura. Ele pode ser instalado assinando com o seu Apple ID
usando ferramentas como AltStore ou Sideloadly.

### Testes

Os testes da ponte rodam em qualquer plataforma:

```sh
cargo test -p anki_ios_bridge
# login real no AnkiWeb (precisa de rede):
cargo test -p anki_ios_bridge -- --ignored
```
