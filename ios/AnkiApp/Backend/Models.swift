// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html

import Foundation

// Types mirroring the JSON produced by ios/bridge/src/commands.rs.

struct DeckNode: Decodable, Identifiable, Hashable {
    let id: Int64
    let name: String
    let level: Int
    let collapsed: Bool
    let filtered: Bool
    let new: Int
    let learn: Int
    let review: Int
    let total: Int
    let children: [DeckNode]

    var childrenOrNil: [DeckNode]? { children.isEmpty ? nil : children }
}

struct DeckTree: Decodable {
    let decks: [DeckNode]
    let currentDeckId: Int64
}

struct DeckName: Decodable, Identifiable, Hashable {
    let id: Int64
    let name: String
}

struct Counts: Decodable, Equatable {
    var new: Int
    var learn: Int
    var review: Int
}

enum AvItem: Decodable, Equatable {
    case sound(filename: String)
    case tts(text: String, lang: String, speed: Float)

    private enum CodingKeys: String, CodingKey {
        case type, filename, text, lang, speed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if try c.decode(String.self, forKey: .type) == "sound" {
            self = .sound(filename: try c.decode(String.self, forKey: .filename))
        } else {
            self = .tts(
                text: try c.decode(String.self, forKey: .text),
                lang: try c.decode(String.self, forKey: .lang),
                speed: try c.decode(Float.self, forKey: .speed)
            )
        }
    }
}

struct QueuedCard: Decodable {
    let cardId: Int64
    let questionHtml: String
    let questionAv: [AvItem]
    let css: String
    let ord: Int
    /// "new", "learn" or "review"
    let queue: String
    /// Intervals for again/hard/good/easy
    let buttonLabels: [String]
    let hasTypeAnswer: Bool
}

struct Congrats: Decodable {
    let learnRemaining: Int
    let secsUntilNextLearn: Int
    let reviewRemaining: Bool
    let newRemaining: Bool
    let haveUserBuried: Bool
    let haveSchedBuried: Bool
    let deckDescription: String
}

struct NextCard: Decodable {
    let card: QueuedCard?
    let counts: Counts
    let deckName: String
    let congrats: Congrats?
}

struct AnswerSide: Decodable {
    let answerHtml: String
    let answerAv: [AvItem]
}

struct SyncAuth: Codable, Equatable {
    var hkey: String
    var endpoint: String?

    var json: [String: Any] {
        ["hkey": hkey, "endpoint": endpoint.map { $0 as Any } ?? NSNull()]
    }
}

struct SyncResult: Decodable {
    /// noChanges, normalSync, fullSync, fullDownload or fullUpload
    let required: String
    let serverMessage: String
    let newEndpoint: String?
    let serverMediaUsn: Int32
}

struct MediaSyncStatus: Decodable {
    let active: Bool
    let error: String?
}

struct NotetypeInfo: Decodable, Identifiable, Hashable {
    let id: Int64
    let name: String
    let fields: [String]
}

struct AddDefaults: Decodable {
    let deckId: Int64
    let notetypeId: Int64
}

struct UndoResult: Decodable {
    let operation: String
}
