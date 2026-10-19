# Handoff — Tarefa T01: RPC genérico na ponte

- **Etapa:** 0 — Fundação (RPC protobuf, páginas web, build/CI, navegação)
- **Status:** concluída com ressalvas (nenhum blocker ou major em aberto; ressalvas menores abaixo)
- **Commit(s):** `a36f13e` (implementação), mais o commit deste handoff

## O que foi feito
- A ponte (`ios/bridge`) agora guarda um único `anki::backend::Backend`, criado com `Backend::new(I18n::new(langs), false)`, como no pylib/rsbridge. A `Collection` própria, o runtime tokio, o cliente reqwest e a thread de sync de mídia foram removidos.
- Nova API C (contrato C1): `AnkiBuffer`, `anki_bridge_rpc` e `anki_bridge_free_buffer`. A semântica é a de `Backend::run_service_method`: em caso de sucesso, o buffer traz a resposta protobuf; com `is_error=true`, traz um `BackendError` codificado.
- Os comandos JSON continuam todos funcionando e usam a mesma coleção do RPC:
  - estudo, adição e baralhos usam `backend.with_col`;
  - open, close, login, sync, fullSync, syncMedia e mediaSyncStatus passam pelos traits `BackendCollectionService` e `BackendSyncService`.
- O backup antes de um full download foi mantido (`maybe_backup(folder, true)` antes de `full_upload_or_download`). `CARD_NOT_CURRENT` também foi mantido.
- Correção de bug: o core devolve `noChanges` depois de um sync normal concluído. A ponte agora compara `sync_meta` (modified, usn) antes e depois. Se houve troca de dados, responde `normalSync` e invalida a carta atual.
- `rslib/src/backend/mod.rs`: a única mudança é que `with_col` passou de `pub(crate)` para `pub`.

## Itens da spec cobertos
| Item | Situação | Onde |
|---|---|---|
| `AnkiBuffer {data,len,is_error}` no header | ✅ | `ios/bridge/include/anki_bridge.h:22` |
| `anki_bridge_rpc` / `anki_bridge_free_buffer` | ✅ | `ios/bridge/src/lib.rs:128`, `:164` |
| Semântica de `run_service_method` | ✅ | `ios/bridge/src/commands.rs:204` |
| Backend inicializado como no rsbridge | ✅ | `ios/bridge/src/commands.rs:190` |
| JSON e RPC compartilham a coleção | ✅ (testado) | `ios/bridge/tests/rpc.rs:81` |
| Mudança mínima em rslib | ✅ (`with_col` pub) | `rslib/src/backend/mod.rs:119` |
| Sync, open e close pelos traits `Backend*Service` | ✅ | `ios/bridge/src/commands.rs:262`, `:709`, `:755`, `:784` |
| Backup antes do full download | ✅ (testado) | `ios/bridge/src/commands.rs:760`, `ios/bridge/tests/sync.rs:90` |
| Teste de RPC real com caminho de erro | ✅ DeckTree, NewDeck/AddDeck, GetDeck NOT_FOUND, PROTO_ERROR, índices inválidos, ABI C | `ios/bridge/tests/rpc.rs:140`, `:177` |

## Arquivos alterados
- `ios/bridge/src/commands.rs`, `ios/bridge/src/lib.rs`, `ios/bridge/include/anki_bridge.h`, `ios/bridge/Cargo.toml`
- `ios/bridge/tests/rpc.rs` e `ios/bridge/tests/sync.rs` (novos)
- `rslib/src/backend/mod.rs`, só a visibilidade de `with_col`
- `Cargo.lock`, por causa da troca de dependências: entraram prost e as dev-deps anki_proto_gen, prost-reflect e tokio; saíram futures, reqwest e tokio. O arquivo está fora da lista de propriedade, mas a mudança é inevitável.
- `ios/handoffs/handoff_tarefa01.md` (este arquivo)

## Como verificar
Antes de rodar os comandos, prepare o ambiente: `git submodule update --init --depth 1 ftl/core-repo ftl/qt-repo` e protoc em `out/extracted/protoc`, como no CI.

| Comando | Resultado |
|---|---|
| `cargo test -p anki_ios_bridge` | unit 2/2, rpc 3/3, study_flow 5 ok + 1 ignorado (precisa do AnkiWeb real), sync 1/1 (cerca de 5 s, servidor local `SimpleServer`) |
| `cargo clippy -p anki_ios_bridge --tests -- -D warnings` | limpo |
| `cargo fmt --check -p anki_ios_bridge` | ok (rustfmt estável; as opções nightly do `rustfmt.toml` foram ignoradas) |
| `just check` | não rodado (build completo pesado) |

- Build Swift: não verificado (sem macOS). O Swift não foi alterado. O header só ganhou declarações novas, e `AnkiBuffer` não colide com nenhum nome usado em `ios/AnkiApp`.

## Resultado da checagem (agente checador)
O checador releu o diff `claude/ios-app...HEAD` e repetiu test, clippy e fmt, todos ok. Achados:

- **Contrato C1:** o header bate exatamente com o contrato. O layout `#[repr(C)]` usa `*mut u8`, `usize` e `bool`, compatíveis com `uint8_t*`, `size_t` e `_Bool`.
  - A liberação via `Box<[u8]>` está correta.
  - `data` vem NULL quando `len == 0`.
  - Um panic na FFI vira `BackendError`.
- **Ordem de locks:** não há deadlock. Só existe aninhamento col → current (`show_answer_inner`, `next_card_inner`). Os outros usos de `current` e de `backup_folder` são temporários, sem chamar `with_col` enquanto o lock está seguro.
- **Equivalência com o comportamento anterior:**
  - O full sync aborta a mídia, reabre a coleção em qualquer resultado e só inicia a mídia em caso de sucesso.
  - O close aborta a mídia e espera ela terminar (`abort_media_sync_and_wait`).
  - Abrir duas vezes e fechar quando já está fechada continuam sendo no-ops.
  - Isso foi conferido contra `rslib/src/backend/sync.rs` e `collection.rs`.
- **Correção `normalSync`:** confirmada. `NormalSyncChecker::sync` termina com `state.required = NoChanges` depois de `finalize`. O `AppModel.swift` já trata `normalSync` no `default:` (`syncGeneration += 1`).
- **Testes:** os índices dos testes vêm de `anki_proto_gen::get_services` sobre `DESCRIPTORS_BIN`, definido em `.cargo/config.toml`, e funcionam no CI Linux atual.
- **Propriedade de arquivos:** só a ressalva do `Cargo.lock`, que é inevitável.
- **Resultado:** nenhum blocker ou major. Não houve correções de código pelo checador. Os pontos menores estão na lista abaixo.

## Pendências e riscos
- (menor) **Mutex envenenado:** o `Backend` usa `lock().unwrap()`. Um panic dentro de `with_col`, por exemplo no código de render da ponte, envenena o mutex da coleção, e todas as chamadas seguintes falham com PANIC até o app reiniciar. A ponte antiga ignorava o envenenamento. Uma mitigação possível é envolver o closure de `Bridge::with_col` em `catch_unwind`.
- (menor) **mediaSyncStatus:** o erro da mídia é reportado uma única vez, na primeira consulta depois do fim do sync, e agora vem localizado (`err.message(tr)`). O app não é afetado, porque para de consultar no primeiro status inativo.
- (menor) **`anki_bridge_abort_sync`:** agora também interrompe o sync normal, com rollback feito pelo backend.
- (menor) **Carta atual do JSON:** não é invalidada por RPCs que mudam a coleção (undo, answer feitos por uma página web). Páginas de estudo vão precisar chamar `selectDeck`/`nextCard` de novo, ou será preciso um gancho de invalidação.
- (menor) **README:** `ios/README.md` ainda descreve a ponte como só JSON. Falta documentar `anki_bridge_rpc`, `AnkiBuffer` e o `data == NULL` quando `len == 0`. O arquivo não pertence a nenhuma tarefa da Etapa 0.

## Dependências para as próximas tarefas
- **T02 (Swift `rpc`):** chamar `anki_bridge_rpc` e tratar `data == NULL` como `Data()` vazio. Liberar sempre com `anki_bridge_free_buffer`, inclusive quando `is_error` for verdadeiro. Se `is_error`, decodificar `Anki_Backend_BackendError`. A função é thread-safe e o backend serializa o acesso à coleção.
- **T02 (índices):** os índices de serviço e método são os de `anki_proto_gen::get_services` (`service.index`, `method.index`), os mesmos do Python/TS.
- **T03:** a coleção precisa estar aberta pelo comando JSON `open`, que o app já usa, antes das RPCs das páginas.
