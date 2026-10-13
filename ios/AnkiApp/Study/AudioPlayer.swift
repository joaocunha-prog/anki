// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html

import AVFoundation

/// Plays a card's [sound:...] files and TTS tags in sequence.
@MainActor
final class AudioPlayer: NSObject {
    private let mediaFolder: URL
    private var pending: [AvItem] = []
    private var player: AVAudioPlayer?
    private let synthesizer = AVSpeechSynthesizer()

    init(mediaFolder: URL) {
        self.mediaFolder = mediaFolder
        super.init()
        synthesizer.delegate = self
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
    }

    func play(_ items: [AvItem]) {
        stop()
        pending = items
        playNext()
    }

    func stop() {
        pending = []
        player?.stop()
        player = nil
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    private func playNext() {
        guard !pending.isEmpty else { return }
        switch pending.removeFirst() {
        case let .sound(filename):
            let url = mediaFolder.appendingPathComponent(filename)
            guard let player = try? AVAudioPlayer(contentsOf: url) else {
                // missing or unsupported file; carry on with the rest
                playNext()
                return
            }
            try? AVAudioSession.sharedInstance().setActive(true)
            player.delegate = self
            self.player = player
            player.play()
        case let .tts(text, lang, speed):
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = AVSpeechSynthesisVoice(language: lang.replacingOccurrences(of: "_", with: "-"))
            let rate = AVSpeechUtteranceDefaultSpeechRate * (speed > 0 ? speed : 1)
            utterance.rate = min(max(rate, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
            synthesizer.speak(utterance)
        }
    }
}

extension AudioPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_: AVAudioPlayer, successfully _: Bool) {
        Task { @MainActor in self.playNext() }
    }
}

extension AudioPlayer: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_: AVSpeechSynthesizer, didFinish _: AVSpeechUtterance) {
        Task { @MainActor in self.playNext() }
    }
}
