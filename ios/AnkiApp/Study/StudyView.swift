// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html

import SwiftUI

struct StudyView: View {
    let deck: DeckNode
    @EnvironmentObject private var model: AppModel
    @StateObject private var session: StudySession
    @Environment(\.colorScheme) private var colorScheme
    @State private var showAddNote = false

    init(deck: DeckNode, backend: AnkiBackend, mediaFolder: URL) {
        self.deck = deck
        _session = StateObject(wrappedValue: StudySession(backend: backend, mediaFolder: mediaFolder))
    }

    var body: some View {
        VStack(spacing: 0) {
            if session.phase == .finished {
                CongratsView(congrats: session.congrats)
            } else {
                CardWebView(
                    html: pageHtml,
                    mediaFolder: model.paths.mediaFolder,
                    proxy: session.webProxy,
                    onPlay: { side, index in session.play(side: side, index: index) },
                    onSubmitTypedAnswer: { Task { await session.showAnswer() } }
                )
                Divider()
                bottomBar
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.bar)
            }
        }
        .navigationTitle(session.deckName.isEmpty ? deck.name : lastComponent(session.deckName))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(lastComponent(session.deckName.isEmpty ? deck.name : session.deckName))
                        .font(.headline)
                        .lineLimit(1)
                    CountsView(counts: session.counts, current: session.card?.queue)
                        .font(.caption.monospacedDigit())
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        Task { await session.undo() }
                    } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                    }
                    Button {
                        session.replay()
                    } label: {
                        Label("Replay Audio", systemImage: "speaker.wave.2")
                    }
                    .disabled(session.card == nil)
                    Button {
                        Task { await session.buryCurrent() }
                    } label: {
                        Label("Bury Card", systemImage: "eye.slash")
                    }
                    .disabled(session.card == nil)
                    Button {
                        Task { await session.suspendCurrent() }
                    } label: {
                        Label("Suspend Card", systemImage: "pause.circle")
                    }
                    .disabled(session.card == nil)
                    Divider()
                    Button {
                        showAddNote = true
                    } label: {
                        Label("Add Note", systemImage: "plus")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showAddNote) {
            AddNoteView()
                .environmentObject(model)
        }
        .alert(
            "Error",
            isPresented: Binding(get: { session.errorMessage != nil }, set: { if !$0 { session.errorMessage = nil } }),
            presenting: session.errorMessage
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
        .task {
            do {
                try await model.selectDeck(deck.id)
            } catch {
                session.errorMessage = error.localizedDescription
            }
            await session.loadNextCard()
        }
        .onChange(of: model.syncGeneration) { _ in
            Task { await session.loadNextCard() }
        }
        .onDisappear {
            session.stopAudio()
            Task { await model.refresh() }
        }
    }

    private var pageHtml: String {
        CardPage.html(
            body: session.bodyHtml,
            css: session.card?.css ?? "",
            ord: session.card?.ord ?? 0,
            nightMode: colorScheme == .dark,
            isAnswer: session.phase == .answer
        )
    }

    @ViewBuilder
    private var bottomBar: some View {
        switch session.phase {
        case .loading, .finished:
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 52)
        case .question:
            Button {
                Task { await session.showAnswer() }
            } label: {
                Text("Show Answer")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
        case .answer:
            HStack(spacing: 8) {
                answerButton(ease: 1, title: "Again", color: .red)
                answerButton(ease: 2, title: "Hard", color: .gray)
                answerButton(ease: 3, title: "Good", color: .green)
                answerButton(ease: 4, title: "Easy", color: .blue)
            }
        }
    }

    private func answerButton(ease: Int, title: LocalizedStringKey, color: Color) -> some View {
        let labels = session.card?.buttonLabels ?? []
        let interval = labels.indices.contains(ease - 1) ? labels[ease - 1] : ""
        return Button {
            Task { await session.answer(ease: ease) }
        } label: {
            VStack(spacing: 2) {
                Text(interval)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .tint(color)
    }

    private func lastComponent(_ name: String) -> String {
        name.components(separatedBy: "::").last ?? name
    }
}

struct CountsView: View {
    let counts: Counts
    /// The queue of the card being shown, which is underlined.
    let current: String?

    var body: some View {
        HStack(spacing: 8) {
            count(counts.new, color: .blue, queue: "new")
            count(counts.learn, color: .red, queue: "learn")
            count(counts.review, color: .green, queue: "review")
        }
    }

    private func count(_ value: Int, color: Color, queue: String) -> some View {
        Text("\(value)")
            .underline(current == queue)
            .foregroundColor(color)
    }
}

struct CongratsView: View {
    let congrats: Congrats?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.green)
                Text("Congratulations! You have finished this deck for now.")
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                if let congrats {
                    if congrats.learnRemaining > 0 {
                        let minutes = max(1, (congrats.secsUntilNextLearn + 59) / 60)
                        Text("The next learning card will be ready in \(minutes) minutes.")
                            .multilineTextAlignment(.center)
                    }
                    if congrats.haveUserBuried || congrats.haveSchedBuried {
                        Text("Some related or buried cards were delayed until a later session.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    }
                    if !congrats.deckDescription.isEmpty {
                        Text(congrats.deckDescription)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity)
        }
    }
}
