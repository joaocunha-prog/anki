# Handoff — Tarefa T05: Navegação base

- **Etapa:** 0 — Fundação (navegação base)
- **Status:** concluída com ressalvas (Swift não compilado neste ambiente Linux)
- **Commit(s):** `6947bb8` (implementação), commit deste handoff na mesma branch `etapa0/T05`

## O que foi feito
- `RootView` passou a mostrar `MainTabView()`, ainda com `.appPresentations(model)` na raiz. O `NavigationStack` saiu da raiz e foi para dentro de cada aba.
- `MainTabView` tem um `TabView` com quatro abas, e a aba selecionada fica em `@SceneStorage("mainTab")` (enum `MainTab: String`):
  - **Baralhos**: `NavigationStack { DeckListView() }`, igual ao comportamento anterior.
  - **Navegar**: placeholder `BrowseTabView`, preenchido na Etapa 3 (T16).
  - **Estatísticas**: placeholder `StatisticsTabView`, preenchido na Etapa 4 (T21) com `WebPageView` na página `graphs`.
  - **Ajustes**: `SettingsTabView`. O item "Sincronização e conta" abre o `SettingsView` existente como sheet, e o item "Coleção" leva à `CollectionView`. As preferências completas ficam para a Etapa 8 (T45).
- `CollectionView` mostra:
  - pasta e caminho completo (selecionável);
  - tamanho do `collection.anki2`;
  - número de arquivos de mídia e o tamanho total deles, lidos fora da thread principal e recarregados quando `syncGeneration` muda;
  - número de baralhos (recursivo sobre `model.decks`) e cartões para hoje (soma do nível superior);
  - `studiedToday`, conta e última sincronização.
- O modificador `.recordsLastSync(model)` grava em UserDefaults (chave `lastSyncDate`) a hora em que uma sincronização termina sem alerta e sem pedido de sincronização unidirecional pendente. Foi preciso porque `AppModel.lastSync` é privado.
- Foram acrescentadas 22 strings novas em pt-BR. Nenhuma linha existente foi alterada.

## Itens da spec cobertos
| Item | Situação | Onde |
|---|---|---|
| RootView mostra MainTabView mantendo `.appPresentations` | ✅ | `ios/AnkiApp/AnkiApp.swift:26-31` |
| Aba Baralhos = NavigationStack{DeckListView} | ✅ | `ios/AnkiApp/Views/MainTabView.swift:22-27` |
| Aba Navegar (placeholder documentado) | ✅ Etapa 3 / T16 | `MainTabView.swift:48-55` |
| Aba Estatísticas (placeholder, futuro WebPageView) | ✅ Etapa 4 / T21 | `MainTabView.swift:57-64` |
| Aba Ajustes usando SettingsView sem editá-lo | ⚠️ abre como sheet a partir de uma lista. Embutido direto na aba, o botão OK (`dismiss()`) não teria efeito e o `.appPresentations` ficaria duplicado com o da raiz (dois `.sheet` ligados a `showLogin` visíveis ao mesmo tempo) | `MainTabView.swift:66-116` |
| CollectionView: caminho, tamanho, nº de baralhos, último sync | ✅ (o último sync é aproximado, ver pendências) | `ios/AnkiApp/Views/CollectionView.swift` |
| CollectionView acessível pelas abas Ajustes ou Navegar | ✅ pela aba Ajustes | `MainTabView.swift:99-105` |
| Strings pt-BR novas | ✅ 22 linhas | `ios/AnkiApp/pt-BR.lproj/Localizable.strings:64-85` |
| Compatibilidade com AppModel, DeckListView e StudyView | ✅ nenhum deles foi alterado | — |

## Arquivos alterados
- `ios/AnkiApp/AnkiApp.swift`
- `ios/AnkiApp/Views/MainTabView.swift` (novo)
- `ios/AnkiApp/Views/CollectionView.swift` (novo)
- `ios/AnkiApp/pt-BR.lproj/Localizable.strings` (só linhas acrescentadas)
- `ios/handoffs/handoff_tarefa05.md` (este arquivo, escrito pelo checador)

## Como verificar
- `git diff claude/ios-app...etapa0/T05 --stat`: só os arquivos da lista de propriedade da T05, mais este handoff.
- Validação do `Localizable.strings` por script Python: as 83 entradas estão no formato `"chave" = "valor";`, nenhuma está duplicada e os especificadores `%` são os mesmos na chave e no valor.
- Todas as chaves usadas no Swift existem no `Localizable.strings`. Algumas já existiam antes: "Decks", "Settings", "Account", "Collection", "AnkiWeb" e o rodapé da pasta Documents. As chaves interpoladas `"Logged in as %@"` e `"%lld files (%@)"` correspondem ao que o `LocalizedStringKey` gera para String e Int.
- Rust: nada foi alterado, então não houve motivo para rodar `cargo test`, `clippy` ou `fmt`.
- Build Swift: **não verificado**, porque não há toolchain Swift neste Linux. A revisão manual cobriu as APIs: todas existem no iOS 16 (`NavigationStack`, `LabeledContent`, `SceneStorage` com enum `RawRepresentable<String>`, `task(id:)`, `onChange` com um parâmetro e `textSelection`). O código é compatível com Swift 5 e com o `@MainActor` de `View` no SDK do iOS 18. A compilação fica para o workflow iOS no macOS.

## Resultado da checagem (agente checador)
- Revisei o diff completo contra o contrato C5 e o enunciado. Não achei nenhum blocker nem major, e nenhuma correção foi necessária.
- Propriedade de arquivos: ok. Os quatro arquivos são da T05.
- Lógica do `recordsLastSync`: o `defer { isSyncing = false }` do `sync()` roda depois de `fullSyncPrompt`/`alertMessage` serem definidos e depois do `refresh()`. Por isso a guarda vê o estado final. Um erro de autenticação faz logout, então também não é registrado. Está correto, dentro da aproximação declarada.
- `dueCount` soma só o nível superior, e isso está correto: no Anki, as contagens do pai já incluem as dos filhos, com os limites aplicados.
- Achados menores (pendentes):
  1. Com o `StudyView` empilhado na aba Baralhos, a barra de abas continua visível durante o estudo. Para escondê-la, seria preciso `.toolbar(.hidden, for: .tabBar)` no `StudyView` ou no `navigationDestination` do `DeckListView`, e nenhum dos dois arquivos é da T05.
  2. O botão de engrenagem do `DeckListView` repete a aba Ajustes.
  3. O último sync é aproximado: uma sincronização interrompida pelo usuário conta como concluída, e uma sincronização bem-sucedida com mensagem do servidor não é registrada. Um erro na sincronização de mídia, que chega depois, também não impede o registro.
  4. O registro do último sync depende de `onChange` numa view. Uma sincronização que termine com o app em segundo plano pode não disparar a atualização da view.

## Pendências e riscos
- Compilar no workflow iOS do macOS.
- Para eliminar a aproximação, o `AppModel` deveria expor `lastSync` (por exemplo, `@Published private(set)`, persistido). Hoje o `AppModel.swift` não pertence a nenhuma tarefa da Etapa 0.
- A T45 (Etapa 8) deve adaptar o `SettingsView` para funcionar embutido na aba (sem o botão OK nem `.appPresentations` próprio) e remover a engrenagem do `DeckListView`.
- A branch foi criada a partir de `claude/ios-app` (9f3011b), depois de um `git reset --hard` feito pelo construtor porque a worktree tinha nascido de `main`.

## Dependências para as próximas tarefas
- T16 (Etapa 3): substituir `BrowseTabView` em `MainTabView.swift`. A aba já está dentro de um `NavigationStack`.
- T21 (Etapa 4): substituir `StatisticsTabView` por um `WebPageView` (T03) na página `graphs`.
- T45 (Etapa 8): expandir `SettingsTabView`. `TabPlaceholder` fica disponível para outras abas vazias.
- Outras telas podem ler o último sync com `@AppStorage(LastSyncRecord.defaultsKey)`, mas isso deve ser substituído quando o `AppModel` passar a expor o `lastSync`.
