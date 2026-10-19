# Handoff — Tarefa T02: Protobuf no Swift

- **Etapa:** 0 — infraestrutura (contrato C2)
- **Status:** concluída com ressalvas (o código Swift ainda não foi compilado)
- **Commit(s):** `150728e` (construtor), `0dd842b` (correções do checador)

## O que foi feito
- Novo gerador `rslib/proto/swift.rs`, chamado por `rslib/proto/build.rs` (`swift::write_swift_interface(&pool, &services)`), que grava `out/ios/generated/BackendServices.swift` (não versionado). O arquivo tem:
  - `enum BackendMethods` com `static let byName: [String: (service: UInt32, method: UInt32)]`, com 250 entradas. As chaves são os nomes camelCase que o TS usa em `/_anki/<nome>`. Os índices vêm de `anki_proto_gen::get_services` (`service.index`/`method.index`), a mesma origem do `python.rs`. `BackendAnkidroidService` fica de fora, como no TS.
  - `BackendMethods.frontendMethods: Set<String>`, com os 27 métodos de FrontendService. Eles estão em `byName`, mas `run_service_method` não os trata.
  - `enum BackendErrorKinds { static let names: [Int: String] }`, gerado a partir de `BackendError.Kind`.
  - `extension AnkiBackend` com um wrapper async tipado para cada método que não é de frontend (223 no total), por exemplo `func getDeck(_ input: Anki_Decks_DeckId) async throws -> Anki_Decks_Deck`. Quando a entrada é Empty, o método não recebe parâmetro. Quando a saída é Empty, ele retorna Void. Se o nome colidir com um membro existente, ganha o sufixo `Rpc` (`abortSync` vira `abortSyncRpc`). Os comentários do .proto viram `///`.
- `ios/gen-swift-protos.sh` roda `protoc --swift_out=out/ios/generated/proto --swift_opt=Visibility=Internal` sobre `proto/anki/*.proto`. Ele usa `out/extracted/protoc` ou o protoc do PATH, e aceita `$PROTOC` e `$PROTOC_GEN_SWIFT`. Se `BackendServices.swift` não existir, gera o arquivo com `cargo build -p anki_proto`.
- `AnkiBackend.swift`:
  - adiciona `rpc(service:method:input:) async throws -> Data`, que chama `anki_bridge_rpc` e `anki_bridge_free_buffer`;
  - em caso de erro, decodifica `Anki_Backend_BackendError` para `BackendError(kind: "SYNC_AUTH_ERROR"…, message:)`;
  - inclui `init(kind:message:)` explícito.
- `ios/AnkiApp/Rpc/BackendRpc.swift`:
  - `rpcMessage(service:method:_:as:)` é o método genérico usado pelos wrappers;
  - `rpc(named:input:)` procura o método em `byName` e recusa os `frontendMethods` com NOT_FOUND_ERROR.

## Itens da spec cobertos
| Item | Situação | Onde |
|---|---|---|
| Gerador `rslib/proto/swift.rs` chamado do build.rs | ✅ | `rslib/proto/build.rs:20` |
| `BackendMethods.byName` com nomes iguais aos do TS | ✅ 250 = 250, sem diferença | `out/ios/generated/BackendServices.swift` |
| Índices iguais aos de `run_service_method` | ✅ conferidos contra `_backend_generated.py` | idem |
| Pular `BackendAnkidroidService` | ✅ | `rslib/proto/swift.rs` (`write_swift_interface`) |
| Métodos tipados async em `extension AnkiBackend` | ✅ 223 wrappers | idem |
| Nomes de tipo no padrão do protoc-gen-swift | ✅ conferido com o `NamingUtils.typePrefix` do swift-protobuf 1.28.2 (`anki.i18n` → `Anki_I18n_`, `anki.import_export` → `Anki_ImportExport_`) | `swift_type()` |
| Aninhadas com `_` | ⚠️ desvio intencional. O protoc-gen-swift gera tipos aninhados (`Anki_Decks_Deck.Normal`), e o gerador segue isso. Nenhuma RPC usa tipo aninhado hoje. | `swift_type()` |
| `ios/gen-swift-protos.sh` | ✅ validado com um protoc-gen-swift falso | `ios/gen-swift-protos.sh` |
| `rpc(service:method:input:)` + BackendError com nome do kind | ✅ (não compilado) | `ios/AnkiApp/Backend/AnkiBackend.swift` |

## Arquivos alterados
- `rslib/proto/swift.rs` (novo) e `rslib/proto/build.rs`
- `ios/gen-swift-protos.sh` (novo)
- `ios/AnkiApp/Backend/AnkiBackend.swift`
- `ios/AnkiApp/Rpc/BackendRpc.swift` (novo)
- `ios/handoffs/handoff_tarefa02.md` (este arquivo)

## Como verificar
- `cargo build -p anki_proto` → ok. Gera `out/ios/generated/BackendServices.swift` com 1241 linhas.
- `cargo clippy -p anki_proto` → sem avisos. `cargo fmt -p anki_proto --check` → ok.
- `cargo test -p anki_ios_bridge` → 2 + 5 ok, 1 ignorado. As mudanças da T01 não estão nesta branch.
- Conferência em Python:
  - os nomes de `byName` são exatamente os `export async function` de `out/ts/lib/generated/backend.ts`;
  - todos os pares `(service, method)` de `_run_command` em `_backend_generated.py` batem;
  - todos os pares usados pelos wrappers existem em `byName`.
- `rm out/ios/generated/BackendServices.swift && PROTOC_GEN_SWIFT=<stub> ios/gen-swift-protos.sh`:
  - o protoc lê todos os `proto/anki/*.proto`;
  - o arquivo é regenerado;
  - exit 0.
- Build Swift: **não verificado**. Não há toolchain Swift no Linux, e os downloads de swift.org/GitHub releases são bloqueados pelo proxy. A primeira execução do workflow iOS (T04) precisa confirmar.

## Resultado da checagem (agente checador)
- **Major, corrigido em `0dd842b`:** o `rpc()` rodava na mesma fila serial dos comandos JSON. Por isso, uma RPC longa bloqueava todas as outras. Exemplo na página deck-options (a página-alvo da T03): durante o `computeFsrsParams`, `runWithBackendProgress` consulta `latestProgress`, e o botão de cancelar chama `setWantsAbort`. Ambos ficariam presos atrás da computação, então o progresso não andaria e cancelar não teria efeito. Agora as RPCs rodam em `rpcQueue`, uma fila concorrente, como as requisições paralelas do mediasrv.py. O `Backend` serializa o acesso à coleção sozinho (`run_service_method` recebe `&self`).
- **Minor, corrigido em `0dd842b`:** `init(serializedData:)` está deprecated no swift-protobuf 1.28 e gerava aviso. Passou a usar `init(serializedBytes:)`. A variável `error`, que era sombreada pelo `catch`, foi renomeada para `decoded`.
- **Minor, corrigido em `0dd842b`:** o `build.rs` só roda de novo quando os .proto mudam. Se alguém apagasse `out/ios/generated`, o `cargo build -p anki_proto` do script não regenerava o arquivo. Agora o script faz `touch rslib/proto/swift.rs` antes do build. Testado.
- Conferido sem problemas:
  - nomes de tipo e prefixos de pacote, comparados com o código do swift-protobuf 1.28.2;
  - nenhuma chave duplicada no literal de dicionário (chave duplicada seria crash em runtime);
  - nenhum wrapper com nome que colida com membros de `AnkiBackend`;
  - `serializedData()` (não deprecated) e `Data(bytes:count:)`;
  - todos os arquivos alterados são de propriedade da T02.

## Pendências e riscos
- Nenhum Swift foi compilado (`AnkiBackend.swift`, `BackendRpc.swift` e o `BackendServices.swift` gerado).
- O gerador só checa nomes reservados em tipos aninhados com uma lista parcial. Se algum dia uma RPC usar um tipo aninhado com nome reservado, ele entra em pânico em vez de gerar um nome errado.
- `abortSyncRpc` é a RPC do backend. Para interromper login/sync iniciados por JSON, continue usando `abortSync()`.

## Dependências para as próximas tarefas
- **T01:**
  - `anki_bridge_rpc` precisa aceitar `input == NULL` quando `input_len == 0`;
  - precisa ser segura para chamadas concorrentes de várias threads, como `Backend::run_service_method`;
  - deve usar o tipo `AnkiBuffer` do C1.
- **T03:**
  - os métodos em `BackendMethods.frontendMethods` não são atendidos pelo backend. O scheme handler deve implementá-los ou responder algo inofensivo, como o mediasrv.py;
  - para os demais, use `backend.rpc(named:input:)` ou `byName` + `rpc(service:method:input:)`.
- **T04:**
  - incluir `out/ios/generated` (com `BackendServices.swift` e `proto/anki/*.pb.swift`) como fonte;
  - adicionar o pacote SwiftProtobuf (from 1.28.0);
  - rodar `ios/gen-swift-protos.sh` depois de `ios/build-rust.sh`, com `brew install swift-protobuf`.
