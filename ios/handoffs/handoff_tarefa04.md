# Handoff — Tarefa T04: CI completo

- **Etapa:** 0 — Fundação (RPC protobuf, páginas web, CI, navegação)
- **Status:** concluída com ressalvas (nada rodou em macOS; depende de T02 e T03 mesclados)
- **Commit(s):** `49a825a` (implementação), commit deste handoff

## O que foi feito
- `ios/project.yml`: pacote SwiftPM `SwiftProtobuf` (https://github.com/apple/swift-protobuf, `from: 1.28.0`) e `- package: SwiftProtobuf` nas dependências do alvo; fonte `../out/ios/generated` (grupo "Generated"); `build/web` como folder reference (`type: folder`, `buildPhase: resources`), que vira a pasta `web/` do bundle. Os dois caminhos são obrigatórios (sem `optional`), como pede o enunciado.
- `ios/build-rust.sh`: se `out/ios/generated/BackendServices.swift` não existe, faz `touch rslib/proto/build.rs` para o cargo rodar o build script de novo mesmo com `target/` em cache. Depois do xcframework, roda `ios/gen-swift-protos.sh` quando o script existe e há `protoc-gen-swift` no PATH (ou `PROTOC_GEN_SWIFT`); `SKIP_SWIFT_PROTOS=1` pula o passo.
- `.github/workflows/ios.yml`:
  - job `web` (ubuntu-24.04): submódulos de tradução, cache do cargo igual ao ci.yml, restauração somente leitura do cache `out` do ci.yml (`build-Linux-main-*`), setup-anki, setup-just, `bash ios/build-web.sh`, checagem de que `ios/build/web` não está vazio, upload do artefato `ios-web` (`if-no-files-found: error`);
  - job `bridge-tests`: sem mudança;
  - job `build` (macos-15, `needs: web`): baixa `ios-web` para `ios/build/web`, `brew install xcodegen swift-protobuf`, `build-rust.sh` (com `SKIP_SWIFT_PROTOS=1`), `gen-swift-protos.sh` como passo próprio (verifica `BackendServices.swift`), `xcodegen generate`, `xcodebuild` simulador e aparelho sem assinatura (`-clonedSourcePackagesDirPath ios/build/spm`), verifica `AnkiiOS.app/web` e empacota/sobe o `.ipa`;
  - gatilhos de caminho incluem também `ts/`, `sass/`, `ftl/`, `build/`, `qt/aqt/data/web/`, `package.json`, `yarn.lock`, `justfile`.
  - Todas as actions fixadas por SHA já usado no repositório (download-artifact `3e5f45b…` = v8.0.1, conferido com `git ls-remote`).
- `ios/.gitignore`: sem mudança (`/build` já ignorado; `out/` ignorado pelo `.gitignore` da raiz).

## Itens da spec cobertos
| Item | Situação | Onde |
|---|---|---|
| SwiftPM swift-protobuf from 1.28.0 | ✅ | `ios/project.yml` (`packages`, `dependencies`) |
| `out/ios/generated` como fonte | ✅ | `ios/project.yml` (`sources`) |
| `ios/build/web` como folder reference "web" | ✅ | `ios/project.yml` (`sources`) |
| build-rust.sh roda gen-swift-protos.sh se houver protoc-gen-swift | ✅ | `ios/build-rust.sh` (final) |
| Job Linux web + artefato consumido pelo macOS | ✅ | `ios.yml` jobs `web` e `build` |
| brew xcodegen + swift-protobuf no CI | ✅ | `ios.yml` passo "Install tools" |
| xcodebuild simulador e aparelho sem assinatura, .ipa | ✅ | `ios.yml` job `build` |
| Job de testes da ponte mantido | ✅ | `ios.yml` job `bridge-tests` |
| Testes Swift (citado em TAREFAS.md) | ⚠️ não há alvo de testes no projeto; fora do contrato C4 | — |
| ci.yml não quebra | ✅ não alterado | — |

## Arquivos alterados
- `ios/project.yml`
- `ios/build-rust.sh`
- `.github/workflows/ios.yml`
- `ios/handoffs/handoff_tarefa04.md` (este arquivo)

## Como verificar
- `python3 -c 'yaml.safe_load(...)'` em `ios.yml`, `ci.yml` e `project.yml` → ok.
- `actionlint` (actionlint-py) em `ios.yml` → sem achados.
- `bash -n` e `shellcheck` em `ios/build-rust.sh` → sem achados.
- Sem mudança em Rust nesta tarefa; cargo não precisou rodar.
- Build Swift/XcodeGen: não verificado (xcodegen/xcodebuild não existem no Linux). Precisa de uma execução real do workflow iOS.

## Resultado da checagem (agente checador)
- Diff revisado contra C4 e o enunciado; propriedade de arquivos respeitada (só arquivos de T04).
- Integração conferida com os ramos irmãos: `etapa0/T02` (`ios/gen-swift-protos.sh` usa o protoc de `out/extracted/protoc` baixado pelo build-rust.sh; `rslib/proto/swift.rs` escreve em `../../out/ios/generated`, mesmo caminho usado aqui) e `etapa0/T03` (`ios/build-web.sh` usa `just build`, que no job `web` tem n2/rsync via setup-anki e `just` via setup-just, e grava em `ios/build/web`).
- SHAs das actions conferidos; download-artifact `3e5f45b…` é a tag v8.0.1 e já é usado em release.yml.
- swift-protobuf: a última tag 1.x hoje é 1.39.0. O SwiftPM resolve a mais nova 1.x e o brew instala um gerador 1.x, então o runtime nunca é mais antigo que o gerador na prática. Não há `Package.resolved` versionado.
- Nenhum blocker/major encontrado; nenhuma correção de código foi necessária.

## Pendências e riscos
- Nada rodou em macOS: XcodeGen e xcodebuild com SwiftPM precisam de uma execução real do workflow.
- O workflow só passa com T02 e T03 mesclados (sem `ios/build-web.sh` o job `web` falha, e o `build` falha junto; sem `gen-swift-protos.sh` o passo de geração falha).
- `xcodegen generate` local exige `out/ios/generated` e `ios/build/web`: rode antes build-rust.sh, gen-swift-protos.sh e build-web.sh. Isso ainda não está documentado em `ios/README.md`, que não pertence a T04.
- Para fixar exatamente swift-protobuf 1.28.x, troque `from` por `exactVersion` e instale o gerador correspondente (por exemplo, compilando `protoc-gen-swift` da mesma tag).
- Não existe alvo de testes Swift; quando houver, acrescente `xcodebuild test` num simulador.
- O job `web` só restaura o cache `out` do ci.yml e nunca o salva, então sem acerto de cache o build completo é lento.
- `upload-artifact` ignora arquivos ocultos por padrão. Hoje as páginas não usam dotfiles.

## Dependências para as próximas tarefas
- T02: `ios/gen-swift-protos.sh` precisa continuar gerando `out/ios/generated/proto/**` e `BackendServices.swift`.
- T03: `ios/build-web.sh` precisa continuar gravando em `ios/build/web` (raiz = conteúdo servido em `/_anki/`).
- Qualquer nova dependência SwiftPM ou fonte gerada entra em `ios/project.yml` (dono: T04).
