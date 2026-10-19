// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html

import AnkiBridge
import Foundation
import SwiftProtobuf

/// An error reported by the Rust core.
struct BackendError: LocalizedError {
    let kind: String
    let message: String

    var errorDescription: String? { message }
    var isAuthError: Bool { kind == "SYNC_AUTH_ERROR" }
    var isInterrupted: Bool { kind == "INTERRUPTED" }
    /// The card on screen was changed elsewhere (eg by a sync), and must be reloaded.
    var isCardNotCurrent: Bool { kind == "CARD_NOT_CURRENT" }

    /// Build from the protobuf BackendError returned by a failed RPC call.
    init(protobuf error: Anki_Backend_BackendError) {
        kind = BackendErrorKinds.names[error.kind.rawValue] ?? "UNKNOWN"
        message = error.message
    }

    init(kind: String, message: String) {
        self.kind = kind
        self.message = message
    }
}

/// Thin async wrapper around the C/JSON bridge. Commands are executed one at
/// a time on a background queue, so the UI never blocks on the collection.
final class AnkiBackend: @unchecked Sendable {
    private let handle: OpaquePointer
    private let queue = DispatchQueue(label: "anki.backend", qos: .userInitiated)
    /// RPC calls may run concurrently, like the web pages' requests on desktop
    /// (mediasrv.py): eg the deck options page polls latestProgress and calls
    /// setWantsAbort while computeFsrsParams is still running. The backend
    /// serializes access to the collection itself.
    private let rpcQueue = DispatchQueue(
        label: "anki.backend.rpc", qos: .userInitiated, attributes: .concurrent
    )

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

    /// Call a backend RPC method with protobuf-encoded input, returning the
    /// protobuf-encoded output. Indices are those of run_service_method; see
    /// BackendMethods (generated) and the typed wrappers in BackendServices.swift.
    /// Shares the collection with the JSON commands. Unlike them, calls are not
    /// queued behind each other (see rpcQueue).
    func rpc(service: UInt32, method: UInt32, input: Data) async throws -> Data {
        let handle = self.handle
        let (output, isError): (Data, Bool) = await withCheckedContinuation { continuation in
            rpcQueue.async {
                let buffer = input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> AnkiBuffer in
                    let bytes = raw.bindMemory(to: UInt8.self)
                    return anki_bridge_rpc(handle, service, method, bytes.baseAddress, bytes.count)
                }
                var output = Data()
                if let data = buffer.data, buffer.len > 0 {
                    output = Data(bytes: data, count: buffer.len)
                }
                let isError = buffer.is_error
                anki_bridge_free_buffer(buffer)
                continuation.resume(returning: (output, isError))
            }
        }
        if isError {
            let decoded: Anki_Backend_BackendError
            do {
                decoded = try Anki_Backend_BackendError(serializedBytes: output)
            } catch {
                throw BackendError(kind: "PROTO_ERROR", message: "Invalid error from backend: \(error)")
            }
            throw BackendError(protobuf: decoded)
        }
        return output
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
