# App do João — Escopos

Fonte: especificação "APP DO JOÃO" (seções 1–11). Base atual: branch `claude/ios-app`
(ponte Rust `ios/bridge` + app SwiftUI `ios/AnkiApp`, já com estudo básico, sync AnkiWeb,
adicionar nota).

## Decisão de arquitetura (vale para todos os escopos)

1. **Núcleo único**: tudo que é regra (SM-2, FSRS 6, busca, baralhos filtrados, importação,
   estatísticas, backups, check database/media, sync) já existe em `rslib/`. O app não
   reimplementa algoritmo nenhum.
2. **RPC genérico**: a ponte passa a expor `Backend::run_service_method` (o mesmo usado por
   Python e TypeScript), dando ao app acesso a todos os ~300 serviços do núcleo.
3. **Reuso das telas web do Anki** (`ts/routes`): opções do baralho, estatísticas, card info,
   editor, image occlusion, trocar tipo de nota, importar CSV/APKG. Rodam em WKWebView com
   um handler `_anki/` que encaminha as chamadas ao núcleo. Assim os comportamentos ficam
   idênticos aos do Anki.
4. **Nativo (SwiftUI)** só onde o iOS exige: revisor, gestos, toque, câmera, microfone,
   Apple Pencil, arquivos, URL schemes.

## Escopos

| Escopo | Seções da spec | Conteúdo |
|---|---|---|
| E0 Fundação | — | RPC genérico, swift-protobuf, host das páginas web, CI macOS ativo |
| E1 Estudo | 1, 4 | Revisor completo, opções do baralho (SM-2/FSRS/FSRS 6), estudo personalizado |
| E2 Criação | 2 | Editor, tipos de nota, mídia, desenho/Pencil, Image Occlusion, templates |
| E3 Organização | 3, 3.1 | Navegador, busca avançada, ações em lote, baralhos, filtrados |
| E4 Estatísticas | 5 | Página de estatísticas, card info, métricas FSRS |
| E5 Interface | 6 | 9 zonas de toque, gestos, toolbars, teclado, gamepad, scratchpad, temas |
| E6 Multimídia | 7 | Controles de áudio/vídeo, gravação de voz, TTS, fontes |
| E7 Dados | 8 | Importar/exportar, AirDrop/Arquivos, backups, check DB/mídia, perfis, servidor próprio |
| E8 Avançado | 9, 10 | URL schemes, x-callback-url, User Actions 1–8, editor de templates, idiomas |
| E9 Auditoria | 11 | Conferência item a item contra a spec, handoff único |

## Fora do escopo (pela própria spec, seção 10)

- Add-ons tradicionais de desktop.
- Complementos Python.

## Bloqueio externo

O Swift só compila em macOS. O GitHub Actions do fork `joaocunha-prog/anki` precisa estar
ativado (Actions → "I understand my workflows, enable them") para que cada etapa seja
validada com build real. Sem isso, a checagem do Swift é só por leitura.
