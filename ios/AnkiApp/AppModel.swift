// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html

import Foundation
import SwiftUI
import UIKit

/// Where the collection lives. Using the Documents folder means the files are
/// visible in the Files app, so they can be backed up or replaced manually.
struct CollectionPaths {
    let folder: URL
    var collection: URL { folder.appendingPathComponent("collection.anki2") }
    var mediaFolder: URL { folder.appendingPathComponent("collection.media") }
    var mediaDb: URL { folder.appendingPathComponent("collection.media.db2") }

    static let standard = CollectionPaths(
        folder: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    )
}

/// Shown when AnkiWeb and the device have diverged, and the user must pick a side.
struct FullSyncPrompt: Identifiable {
    let id = UUID()
    let serverMediaUsn: Int32
}

@MainActor
final class AppModel: ObservableObject {
    let backend = AnkiBackend()
    let paths = CollectionPaths.standard

    @Published private(set) var decks: [DeckNode] = []
    @Published private(set) var currentDeckId: Int64 = 1
    @Published private(set) var studiedToday = ""
    @Published private(set) var isOpen = false
    @Published private(set) var auth: SyncAuth?
    @Published private(set) var isSyncing = false
    @Published private(set) var isSyncingMedia = false
    @Published var fullSyncPrompt: FullSyncPrompt?
    @Published var alertMessage: String?
    @Published var showLogin = false

    @AppStorage("username") var username = ""
    /// Optional self-hosted sync server, eg http://192.168.1.2:8080/
    @AppStorage("customSyncServer") var customSyncServer = ""
    @AppStorage("autoSync") var autoSync = true

    private var lastSync = Date.distantPast

    init() {
        auth = Keychain.loadAuth()
    }

    var isLoggedIn: Bool { auth != nil }

    // Collection
    //////////////

    func start() async {
        do {
            try FileManager.default.createDirectory(at: paths.mediaFolder, withIntermediateDirectories: true)
            try await backend.run([
                "cmd": "open",
                "collectionPath": paths.collection.path,
                "mediaFolder": paths.mediaFolder.path,
                "mediaDb": paths.mediaDb.path,
            ])
            isOpen = true
        } catch {
            alertMessage = error.localizedDescription
            return
        }
        await refresh()
        if isLoggedIn && autoSync {
            await sync()
        }
    }

    func refresh() async {
        guard isOpen else { return }
        do {
            let tree = try await backend.call(DeckTree.self, ["cmd": "deckTree"])
            decks = tree.decks
            currentDeckId = tree.currentDeckId
            studiedToday = try await backend.call(String.self, ["cmd": "studiedToday"])
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    // Login
    //////////////

    func login(username: String, password: String) async throws {
        let endpoint = customSyncServer.trimmingCharacters(in: .whitespaces)
        let auth = try await backend.call(SyncAuth.self, [
            "cmd": "login",
            "username": username,
            "password": password,
            "endpoint": endpoint.isEmpty ? NSNull() as Any : endpoint as Any,
        ])
        self.username = username
        setAuth(auth)
        showLogin = false
        await sync()
    }

    func logout() {
        setAuth(nil)
    }

    private func setAuth(_ auth: SyncAuth?) {
        self.auth = auth
        if let auth {
            Keychain.saveAuth(auth)
        } else {
            Keychain.deleteAuth()
        }
    }

    // Syncing
    //////////////

    /// Sync with AnkiWeb, prompting for login if required.
    func sync() async {
        guard let auth else {
            showLogin = true
            return
        }
        guard isOpen, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let result = try await backend.call(SyncResult.self, [
                "cmd": "sync",
                "auth": auth.json,
                "syncMedia": true,
            ])
            lastSync = Date()
            if let endpoint = result.newEndpoint, !endpoint.isEmpty {
                var updated = auth
                updated.endpoint = endpoint
                setAuth(updated)
            }
            if !result.serverMessage.isEmpty {
                alertMessage = result.serverMessage
            }
            switch result.required {
            case "fullDownload":
                // nothing on this device yet, so no need to ask
                try await fullSync(upload: false, serverMediaUsn: result.serverMediaUsn)
            case "fullUpload":
                // nothing on AnkiWeb yet
                try await fullSync(upload: true, serverMediaUsn: result.serverMediaUsn)
            case "fullSync":
                fullSyncPrompt = FullSyncPrompt(serverMediaUsn: result.serverMediaUsn)
            default:
                monitorMediaSync()
            }
        } catch {
            handleSyncError(error)
        }
        await refresh()
    }

    /// Resolve a conflict by replacing one side with the other.
    func resolveFullSync(upload: Bool, serverMediaUsn: Int32?) async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            try await fullSync(upload: upload, serverMediaUsn: serverMediaUsn)
        } catch {
            handleSyncError(error)
        }
        await refresh()
    }

    func abortSync() {
        backend.abortSync()
    }

    private func fullSync(upload: Bool, serverMediaUsn: Int32?) async throws {
        guard let auth else { return }
        try await backend.run([
            "cmd": "fullSync",
            "auth": auth.json,
            "upload": upload,
            "serverMediaUsn": serverMediaUsn.map { $0 as Any } ?? NSNull(),
        ])
        lastSync = Date()
        monitorMediaSync()
    }

    private func handleSyncError(_ error: Error) {
        if let error = error as? BackendError {
            if error.isInterrupted {
                return
            }
            if error.isAuthError {
                logout()
                showLogin = true
            }
        }
        alertMessage = error.localizedDescription
    }

    /// Media is synced in the background; poll until it completes.
    private func monitorMediaSync() {
        guard !isSyncingMedia else { return }
        isSyncingMedia = true
        Task {
            defer { isSyncingMedia = false }
            while true {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let status = try? await backend.call(MediaSyncStatus.self, ["cmd": "mediaSyncStatus"])
                else { return }
                if !status.active {
                    if let error = status.error {
                        alertMessage = error
                    }
                    return
                }
            }
        }
    }

    /// Called when the app moves between foreground and background.
    func scenePhaseChanged(_ phase: ScenePhase) {
        guard isOpen, isLoggedIn, autoSync else { return }
        switch phase {
        case .background:
            // Push the day's reviews up, as the desktop app does on close.
            let task = UIApplication.shared.beginBackgroundTask(withName: "sync")
            Task {
                await sync()
                UIApplication.shared.endBackgroundTask(task)
            }
        case .active:
            if Date().timeIntervalSince(lastSync) > 5 * 60 {
                Task { await sync() }
            }
        default:
            break
        }
    }

    // Decks
    //////////////

    func selectDeck(_ deckId: Int64) async throws {
        try await backend.run(["cmd": "selectDeck", "deckId": deckId])
        currentDeckId = deckId
    }
}
