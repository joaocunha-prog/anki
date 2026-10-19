# Handoff — Tarefa T03: Host das páginas web

- **Etapa:** 0 — Fundações (RPC protobuf, páginas web, build/CI, navegação)
- **Status:** concluída com ressalvas (build web e Swift não verificados neste Linux)
- **Commit(s):** `b2af32e` (implementação), `ad748fb` (correção da checagem), commit deste handoff

## O que foi feito
- `ios/build-web.sh`: roda `just build` (não existe receita só das páginas; `just rebuild-web` recarrega webviews do desktop e não serve aqui), que gera `out/qt/_aqt/data/web/`, e copia o resultado sem `*.map` para `ios/build/web/` mantendo o layout que o desktop serve em `/_anki/` (`pages/`, `sveltekit/index.html` + `sveltekit/_app/`, `css/`, `js/`, `imgs/`). Busca os submódulos `ftl/` se faltarem. `SKIP_WEB_BUILD=1` só copia; `WEB_OUT=<dir>` muda o destino.
- `ios/AnkiApp/Web/AnkiWebSchemeHandler.swift`: `WKURLSchemeHandler` de `anki-web://localhost/`, espelhando `qt/aqt/mediasrv.py`:
  - GET: rotas SvelteKit (as 11 de `get_sveltekit_route`) → `sveltekit/index.html`; `/_app/…`; `/_anki/…` com remapeamento legado de css/js/jquery; `favicon.ico`; demais caminhos → pasta de mídia opcional com `UNTRUSTED_MEDIA_CSP`. MIME fixo como `_mime_for_path`, proteção contra traversal, CSPs (trusted remove o meta do SvelteKit; editor/image-occlusion usam script-src com hash), cache longo para `immutable`.
  - POST `/_anki/<método>`: `Content-Type` diferente de `application/binary` → 403; métodos limitados a `exposed_backend_list` + handlers Python replicados; chama `backend.rpc(service:method:input:)` via `BackendMethods.byName`; saída não vazia → 200 `application/binary`, vazia → 204, erro → 500 com a mensagem em texto (como o desktop). `Anki-Op-Changes` ≠ 0 → `webPageDidChangeCollection()`.
- `ios/AnkiApp/Web/WebPageView.swift`: `UIViewRepresentable` que abre `anki-web://localhost/<path>` (+ `#night` no modo escuro), injeta o estilo dinâmico do desktop e um shim `bridgeCommand`/`pycmd` (`browserSearch:`), implementa alert/confirm/prompt, abre links externos no navegador e recarrega se o processo web morrer. `WebPageProxy.requestClose()` chama `anki.deckOptionsPendingChanges()` como o `closeEvent` do desktop.

## Itens da spec cobertos
| Item | Situação | Onde |
|---|---|---|
| `ios/build-web.sh` via justfile, saída em `ios/build/web` | ⚠️ escrito e testado só no modo cópia; build real bloqueado pela rede (ver abaixo) | `ios/build-web.sh` |
| GET estático com MIME correto | ✅ | `AnkiWebSchemeHandler.swift:148` (`resolve`), `:211`, `:338` |
| POST `/_anki/<método>` → `backend.rpc` via `BackendMethods.byName`, `application/binary`, erro 500 | ✅ | `AnkiWebSchemeHandler.swift:375`, `:420`, `:512` |
| Abertura das páginas como o desktop | ✅ com desvio documentado: páginas SvelteKit abrem na raiz (`deck-options/<id>`, `graphs`, `card-info/<id>`), igual a `load_sveltekit_page`; `_anki/pages/<nome>.html` (`load_ts_page`) também funciona | `AnkiWebSchemeHandler.swift:75`, `WebPageView.swift:54` |
| `WebPageView` (UIViewRepresentable) | ✅ | `WebPageView.swift:54` |
| Lista de endpoints replicados / pendentes | ✅ | doc comment em `AnkiWebSchemeHandler.swift:49-65` e abaixo |

Endpoints especiais de `mediasrv.py`:
- **Replicados:** `congratsInfo` e `getDeckConfigsForUpdate` (repassados ao backend; `congratsInfo` sem a troca para a tela de overview), `updateDeckConfigs` (espera o salvamento e fecha a página, exceto em `COMPUTE_ALL_PARAMS`), `deckOptionsReady`, `deckOptionsRequireClose`, `getConfigJson` (`null` em `NOT_FOUND_ERROR`), `get/setProfileConfigJson` e `get/setMetaJson` (UserDefaults), `openLink`, `searchInBrowser` (via `buildSearchString`), `askUser`, `showMessageBox`; `i18nResources` vai direto ao backend.
- **Para etapas seguintes (404):** `getSchedulingStatesWithContext`, `setSchedulingStates`, `changeNotetype`, `importDone`, `importDialogRequireClose`, e os do editor: `convertPastedImage`, `openFilePicker`, `openMedia`, `showInMediaFolder`, `recordAudio`, `playFile`, `readClipboard`, `writeClipboard`, `closeAddCards`, `closeEditCurrent`, `openFieldsDialog`, `openCardsDialog`, `saveCustomColours`. Também não: `legacyPageData`, `/_addons/`, e o refresh completo de op-changes (reduzido ao callback).

## Arquivos alterados
- `ios/build-web.sh` (novo)
- `ios/AnkiApp/Web/AnkiWebSchemeHandler.swift` (novo)
- `ios/AnkiApp/Web/WebPageView.swift` (novo)
- `ios/handoffs/handoff_tarefa03.md` (este arquivo)

Nenhum arquivo de outra tarefa foi tocado.

## Como verificar
- `bash -n ios/build-web.sh` → ok.
- `ios/build-web.sh` completo (rodado de novo pelo checador): falha em `yarn install --immutable`; o corepack tenta baixar yarn 4.11.0 de `https://repo.yarnpkg.com`, e o proxy da sessão responde 403. Antes disso o ambiente Python e as ferramentas de build compilaram. Não foi contornado.
- `SKIP_WEB_BUILD=1 WEB_OUT=<scratch> ios/build-web.sh` com um `out/qt/_aqt/data/web` simulado → copia, exclui `.map`; sem `sveltekit/index.html` → erro claro e saída 1.
- Build Swift: não verificado (sem toolchain Swift/UIKit/WebKit no Linux). Deve ser confirmado no workflow iOS (macos-15, SDK iOS 18). Nomes de tipos e API conferidos contra a branch `etapa0/T02` (`AnkiBackend.rpc`, `BackendError.kind` com nomes do proto como `NOT_FOUND_ERROR`, `BackendMethods.byName`) e os `.proto` (`Anki_Generic_String/Json/Bool`, `Anki_Frontend_AskUserRequest/ShowMessageBoxRequest/SetSettingJsonRequest`, `Anki_DeckConfig_UpdateDeckConfigsRequest`, modo 2 = `COMPUTE_ALL_PARAMS`).
- Sem mudanças em Rust nesta tarefa (cargo test/clippy/fmt não se aplicam).

## Resultado da checagem (agente checador)
- Diff lido inteiro e comparado com `mediasrv.py` (`_extract_internal_request`, `_handle_builtin_file_request`, CSPs, `post_handler_list`, `exposed_backend_list`, `_check_dynamic_request_permissions`), `deckoptions.py`, `webview.py` e `ts/lib/generated/post.ts`.
- A lista `exposedBackendMethods` bate com `exposed_backend_list`. Os métodos importados de `@generated/backend` por `ts/routes` que não estão liberados são só os handlers Python listados como pendentes.
- Os tipos de retorno conferem com o desktop: `askUser`/`showMessageBox` devolvem `generic.Bool` como o Python, embora o `.proto` declare `Empty` para `ShowMessageBox`.
- O layout de `ios/build/web` é o que o job `web` do T04 publica e que o app lê em `Bundle.main.url(forResource: "web")`.
- **Corrigido (minor, `ad748fb`):** `build-web.sh` checava `ftl/core-repo/core/sync.ftl`, que não existe (os arquivos ficam em pastas por idioma), e por isso sempre rodava `git submodule update`. Agora checa `ftl/*-repo/l10n.toml`.
- Achados minor que continuam pendentes:
  - O POST sem `Content-Type` é aceito; o desktop exige o header. O risco é baixo porque só páginas do próprio web view chegam ao esquema.
  - `WebPageView` monta a URL com `URL(string:)` sem percent-encoding: se o `path` tiver espaço (ex.: `import-csv/<arquivo>`), a página não carrega e nenhum erro aparece. Quem chama deve codificar o caminho.
  - `askUser` ignora `defaultNo`.
  - O modo noturno só é decidido ao carregar a página.
- Não há blocker nem major.

## Pendências e riscos
- O build web real precisa ser confirmado no job Linux do T04 (`ios/build-web.sh` → artefato `ios-web`).
- O Swift não foi compilado. No CI macOS, conferir o isolamento `@MainActor` de `WKURLSchemeHandler`/`WKUIDelegate`, os métodos async do `WKUIDelegate` e os nomes gerados pelo protoc-gen-swift.
- Testar em simulador ou aparelho: o carregamento de ES modules e o `fetch` POST no esquema `anki-web://localhost`, e se o corpo do POST chega em `httpBody` ou em `httpBodyStream` (os dois são tratados).
- `updateDeckConfigs` não tem UI de progresso: a página espera o salvamento terminar.
- Os botões "Yes"/"No" dos alertas ainda não têm tradução pt-BR; o `Localizable.strings` é do T05.

## Dependências para as próximas tarefas
- T04: incluir `ios/AnkiApp/Web/*.swift` no target e `ios/build/web` como folder reference chamada `web`.
- T05/Etapas seguintes: para usar, `WebPageView(backend:path:onClose:)`, por exemplo `path: "graphs"` na aba Estatísticas ou `"deck-options/\(deckId)"`. Para fechar com confirmação, use `WebPageProxy.requestClose()`.
- Endpoints pendentes do reviewer, do editor e da importação devem ser adicionados em `postHandler(for:)` quando a página correspondente for usada.
