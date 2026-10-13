// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html

import AnkiBridge
import Foundation

/// An error reported by the Rust core.
struct BackendError: LocalizedError {
    let kind: String
    let message: String

    var errorDescription: String? { message }
    var isAuthError: Bool { kind == "SYNC_AUTH_ERROR" }
    var isInterrupted: Bool { kind == "INTERRUPTED" }
}

/// Thin async wrapper around the C/JSON bridge. Commands are executed one at
/// a time on a background queue, so the UI never blocks on the collection.
final class AnkiBackend: @unchecked Sendable {
    private let handle: OpaquePointer
    private let queue = DispatchQueue(label: "anki.backend", qos: .userInitiated)

    init() {
        let langs = Locale.preferredLanguages.joined(separator: ",")
        handle = anki_bridge_new(langs)
    }

    deinit {
        anki_bridge_free(handle)
    }

    /// Run a command, returning the decoded `ok` value.
    func call<T: Decodable>(_ type: T.Type, _ command: [String: Any]) async throws -> T {
        let data = try await callRaw(command)
        return try JSONDecoder().decode(type, from: data)
    }

    /// Run a command whose result is not needed.
    func run(_ command: [String: Any]) async throws {
        _ = try await callRaw(command)
    }

    /// Interrupt a login or full sync. Safe to call while a command is running.
    func abortSync() {
        anki_bridge_abort_sync(handle)
    }

    private func callRaw(_ command: [String: Any]) async throws -> Data {
        let input = try String(decoding: JSONSerialization.data(withJSONObject: command), as: UTF8.self)
        let handle = self.handle
        let output: String = await withCheckedContinuation { continuation in
            queue.async {
                let ptr = anki_bridge_command(handle, input)!
                let text = String(cString: ptr)
                anki_bridge_free_string(ptr)
                continuation.resume(returning: text)
            }
        }
        let reply = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any] ?? [:]
        if let error = reply["error"] as? [String: Any] {
            throw BackendError(
                kind: error["kind"] as? String ?? "UNKNOWN",
                message: error["message"] as? String ?? "Unknown error"
            )
        }
        return try JSONSerialization.data(withJSONObject: reply["ok"] ?? NSNull(), options: .fragmentsAllowed)
    }
}
