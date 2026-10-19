# App do João — Etapas e tarefas

Cada etapa = 1 escopo = 5 tarefas, executadas por **10 agentes simultâneos**:
5 construtores (um por tarefa, cada um em sua worktree) e 5 checadores (cada um revisa
adversarialmente a tarefa do seu par, assim que ela termina). Uma tarefa só fecha quando o
checador aprova, os testes passam e o arquivo `ios/handoffs/handoff_tarefaNN.md` está escrito
(modelo em `ios/handoffs/TEMPLATE.md`).

Critério de pronto de toda tarefa:
- Rust: `cargo test -p anki_ios_bridge`, clippy e rustfmt limpos.
- Swift: compila no workflow `iOS` (macOS) quando o Actions estiver ativo.
- Cada item da spec citado na tarefa está implementado ou marcado com motivo no handoff.

Status: ⬜ pendente · 🟨 em andamento · ✅ concluída

---

## Etapa 0 — Fundação

| # | Tarefa | Entrega |
|---|---|---|
| T01 ⬜ | RPC genérico na ponte | Ponte passa a usar `anki::backend::Backend`; novo `anki_bridge_rpc(service, method, bytes)`; comandos JSON atuais mantidos sobre o mesmo backend; testes |
| T02 ⬜ | Protobuf no Swift | Geração de código swift-protobuf a partir de `proto/` no build; cliente `Rpc.swift` tipado |
| T03 ⬜ | Host das páginas web | Build das páginas `ts/` no CI, embutidas no app; `WebPageView` com handler `_anki/` que roteia POSTs ao RPC |
| T04 ⬜ | CI completo | Workflow: job Linux gera páginas web → job macOS embute, compila simulador/aparelho, roda testes Swift |
| T05 ⬜ | Navegação base | Estrutura de abas/menus que as próximas etapas preenchem; tela de perfil/coleção |

## Etapa 1 — Estudo (spec 1 e 4)

| # | Tarefa | Itens da spec |
|---|---|---|
| T06 ⬜ | Revisor completo | Active recall, 4 botões, next review times, undo, leech, bury siblings (respeitado), auto advance |
| T07 ⬜ | Ações no cartão | Set due date, reset card, suspend/unsuspend, bury/unbury, flags, marked, card info (página web) |
| T08 ⬜ | Opções do baralho | Página `deck-options`: SM-2, FSRS, FSRS 6, learning/relearning steps, desired retention, maximum interval, daily limits, bury siblings, leech |
| T09 ⬜ | Estudo personalizado | Custom study: review forgotten, review ahead, increase new/review limit, preview new, by tag, by state |
| T10 ⬜ | Sessões filtradas no revisor | Study ahead, no rescheduling, preview sem agendar, congrats page |

## Etapa 2 — Criação e edição (spec 2)

| # | Tarefa | Itens da spec |
|---|---|---|
| T11 ⬜ | Editor de notas | Página `editor`: campos, formatação, HTML, tags, Basic/Reversed/Cloze/Nested Cloze/Type in answer, campos adicionais |
| T12 ⬜ | Mídia no editor | Imagens, áudio, vídeo, câmera/galeria, gravação de áudio, anexos |
| T13 ⬜ | Desenho | Desenhos nos cartões com PencilKit (Apple Pencil) salvos como imagem |
| T14 ⬜ | Image Occlusion | Página `image-occlusion`: criar e editar oclusões no aparelho |
| T15 ⬜ | Tipos de nota e preview | Editor de templates (frente, verso, CSS), preview, change note type, MathJax/LaTeX, JavaScript nos cartões |

## Etapa 3 — Organização (spec 3)

| # | Tarefa | Itens da spec |
|---|---|---|
| T16 ⬜ | Navegador | Lista de cartões/notas, colunas, ordenação, busca avançada (todos os operadores da 3.1) |
| T17 ⬜ | Ações em lote | Bulk actions, move cards, reposition, flags, marked, tags, browser bulk editing |
| T18 ⬜ | Tags | Etiquetas hierárquicas: listar, renomear, excluir, filtrar |
| T19 ⬜ | Baralhos | Criar, subdecks, renomear, excluir, mover |
| T20 ⬜ | Baralhos filtrados | Criar com busca/ordem, rebuild, empty, rescheduling toggle |

## Etapa 4 — Estatísticas (spec 5)

| # | Tarefa | Itens da spec |
|---|---|---|
| T21 ⬜ | Página de estatísticas | Página `graphs`: today, review count, study time, calendar, future due, card counts, intervals, answer buttons, hourly, ease, stability, difficulty, retrievability, true retention |
| T22 ⬜ | Card info / histórico | Página `card-info` a partir do revisor e do navegador |
| T23 ⬜ | Estatística por baralho | Seleção de baralho/coleção e período; respeitar SM-2 vs FSRS |
| T24 ⬜ | Erros recorrentes | Acesso rápido a leeches, lapses e rated:1 |
| T25 ⬜ | Testes de estatística | Testes da ponte com revlog sintético conferindo números |

## Etapa 5 — Interface e controles (spec 6)

| # | Tarefa | Itens da spec |
|---|---|---|
| T26 ⬜ | Zonas de toque | 9 zonas configuráveis, ações distintas para frente e verso |
| T27 ⬜ | Gestos | Swipes 4 direções, shake action, double-tap prevention, feedback ticks |
| T28 ⬜ | Toolbars e exibição | Top toolbar customizável, bottom toolbar opcional, night mode, theme colors, text zoom, scroll actions |
| T29 ⬜ | Teclado e gamepad | Atalhos de teclado externo, GameController framework, mapeamento de comandos |
| T30 ⬜ | Scratchpad | Área de desenho no revisor com sensibilidade à pressão |

## Etapa 6 — Multimídia (spec 7)

| # | Tarefa | Itens da spec |
|---|---|---|
| T31 ⬜ | Áudio | Playback, replay, pause/resume, seek ±5 s, autoplay, offline |
| T32 ⬜ | Vídeo | Playback e loop de vídeos dos cartões |
| T33 ⬜ | Gravar voz | Gravação temporária e reprodução para comparar pronúncia |
| T34 ⬜ | TTS | Tags `{{tts}}`, vozes do sistema, idioma/velocidade |
| T35 ⬜ | Fontes | Fontes incorporadas (`_fonte.ttf` na mídia) servidas ao WebView |

## Etapa 7 — Dados e segurança (spec 8)

| # | Tarefa | Itens da spec |
|---|---|---|
| T36 ⬜ | Importação | APKG, COLPKG, CSV/TSV (páginas `import-*`), preservando mídia, tipos de nota, IDs e agendamento |
| T37 ⬜ | Exportação e transferência | Export collection/deck, compartilhar (AirDrop), Arquivos/Finder, abrir .apkg vindo de outros apps, shared decks (ankiweb.net/shared) |
| T38 ⬜ | Backups | Automáticos, restaurar, mídia tratada à parte (spec 8) |
| T39 ⬜ | Manutenção | Check database, check media (ausentes/não usados) |
| T40 ⬜ | Perfis e servidor próprio | Múltiplos perfis, self-hosted sync avançado, sync de histórico/mídia, one-way |

## Etapa 8 — Avançado (spec 9 e 10)

| # | Tarefa | Itens da spec |
|---|---|---|
| T41 ⬜ | URL schemes | `anki://`, x-callback-url, add note programático, abrir baralho |
| T42 ⬜ | JavaScript nos cartões | User Actions 1–8, compatibilidade do ambiente de execução |
| T43 ⬜ | Dicionários externos | Links e esquemas de URL a partir dos cartões |
| T44 ⬜ | Idiomas | Interface multilíngue usando as traduções `ftl/` do núcleo |
| T45 ⬜ | Preferências | Tela de preferências reunindo as opções das etapas anteriores |

## Etapa 9 — Auditoria e entrega

| # | Tarefa | Entrega |
|---|---|---|
| T46 ⬜ | Auditoria spec 1–4 | Checagem item a item, abre correções |
| T47 ⬜ | Auditoria spec 5–8 | Idem |
| T48 ⬜ | Auditoria spec 9–11 | Idem |
| T49 ⬜ | Correções finais | Fecha o que as auditorias apontarem |
| T50 ⬜ | Handoff único | `ios/handoffs/HANDOFF_FINAL.md` consolidando T01–T49 |
