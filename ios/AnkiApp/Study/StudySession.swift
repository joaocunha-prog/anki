// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html

import Foundation

/// Drives the review screen: fetches cards, reveals answers and records
/// ratings. Scheduling itself happens in the Rust core.
@MainActor
final class StudySession: ObservableObject {
    enum Phase {
        case loading
        case question
        case answer
        case finished
    }

    @Published private(set) var phase = Phase.loading
    @Published private(set) var card: QueuedCard?
    @Published private(set) var counts = Counts(new: 0, learn: 0, review: 0)
    @Published private(set) var deckName = ""
    @Published private(set) var congrats: Congrats?
    /// Body HTML of the side currently shown.
    @Published private(set) var bodyHtml = ""
    @Published var errorMessage: String?

    let webProxy = CardWebViewProxy()
    private let backend: AnkiBackend
    private let audio: AudioPlayer
    private var questionAv: [AvItem] = []
    private var answerAv: [AvItem] = []
    private var shownAt = Date()
    private var busy = false

    init(backend: AnkiBackend, mediaFolder: URL) {
        self.backend = backend
        audio = AudioPlayer(mediaFolder: mediaFolder)
    }

    func loadNextCard() async {
        do {
            let next = try await backend.call(NextCard.self, ["cmd": "nextCard"])
            counts = next.counts
            deckName = next.deckName
            card = next.card
            congrats = next.congrats
            answerAv = []
            if let card = next.card {
                questionAv = card.questionAv
                bodyHtml = card.questionHtml
                phase = .question
                shownAt = Date()
                if card.autoplay {
                    audio.play(questionAv)
                } else {
                    audio.stop()
                }
            } else {
                questionAv = []
                bodyHtml = ""
                phase = .finished
                audio.stop()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func showAnswer() async {
        guard phase == .question, let card, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            var command: [String: Any] = ["cmd": "showAnswer", "cardId": card.cardId]
            if card.hasTypeAnswer {
                command["typed"] = await webProxy.typedAnswer()
            }
            let answer = try await backend.call(AnswerSide.self, command)
            answerAv = answer.answerAv
            bodyHtml = answer.answerHtml
            phase = .answer
            if card.autoplay {
                audio.play(answerAv)
            } else {
                audio.stop()
            }
        } catch {
            await handle(error)
        }
    }

    /// ease: 1=again, 2=hard, 3=good, 4=easy
    func answer(ease: Int) async {
        guard phase == .answer, let card, !busy else { return }
        busy = true
        defer { busy = false }
        // like the desktop's default, cap the recorded time at 60 seconds
        let millis = min(Int(Date().timeIntervalSince(shownAt) * 1000), 60000)
        do {
            try await backend.run([
                "cmd": "answer",
                "cardId": card.cardId,
                "ease": ease,
                "millisecondsTaken": millis,
            ])
        } catch {
            await handle(error)
            return
        }
        await loadNextCard()
    }

    func undo() async {
        do {
            _ = try await backend.call(UndoResult.self, ["cmd": "undo"])
        } catch {
            errorMessage = error.localizedDescription
        }
        await loadNextCard()
    }

    func buryCurrent() async {
        await act(on: "buryCard")
    }

    func suspendCurrent() async {
        await act(on: "suspendCard")
    }

    private func act(on cmd: String) async {
        guard let card else { return }
        do {
            try await backend.run(["cmd": cmd, "cardId": card.cardId])
        } catch {
            errorMessage = error.localizedDescription
        }
        await loadNextCard()
    }

    func replay() {
        if phase == .answer {
            audio.play((card?.replayQuestion ?? true ? questionAv : []) + answerAv)
        } else {
            audio.play(questionAv)
        }
    }

    /// If the card changed underneath us (eg a sync), show the up-to-date
    /// card instead of an error.
    private func handle(_ error: Error) async {
        if let error = error as? BackendError, error.isCardNotCurrent {
            await loadNextCard()
        } else {
            errorMessage = error.localizedDescription
        }
    }

    func play(side: String, index: Int) {
        let items = side == "q" ? questionAv : answerAv
        if items.indices.contains(index) {
            audio.play([items[index]])
        }
    }

    func stopAudio() {
        audio.stop()
    }
}
