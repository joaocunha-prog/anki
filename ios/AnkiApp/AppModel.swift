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
    var backups: URL { folder.appendingPathComponent("backups") }

    static let standard = CollectionPaths(
        folder: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    )
}

/// Asks the user to confirm a one-way sync, as the desktop app does.
struct FullSyncPrompt: Identifiable {
    enum Kind {
        /// Both sides changed; the user must pick one.
        case conflict
        /// This device has no cards; download AnkiWeb's collection.
        case download
        /// AnkiWeb has no cards; upload this device's collection.
        case upload
    }

    let id = UUID()
    let kind: Kind
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
    /// True while the running sync step can be interrupted (login, full sync).
    @Published private(set) var canAbortSync = false
    @Published private(set) var isSyncingMedia = false
    /// Incremented when a sync may have changed the collection, so open
    /// screens can reload.
    @Published private(set) var syncGeneration = 0
    @Published var fullSyncPrompt: FullSyncPrompt?
    @Published var alertMessage: String?
    @Published var showLogin = false
    /// Shown on the login screen, eg after AnkiWeb rejected the saved login.
    @Published var loginMessage: String?

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
            try FileManager.default.createDirectory(at: paths.backups, withIntermediateDirectories: true)
            try await backend.run([
                "cmd": "open",
                "collectionPath": paths.collection.path,
                "mediaFolder": paths.mediaFolder.path,
                "mediaDb": paths.mediaDb.path,
                "backupFolder": paths.backups.path,
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
        canAbortSync = true
        defer { canAbortSync = false }
        let auth = try await backend.call(SyncAuth.self, [
            "cmd": "login",
            "username": username,
            "password": password,
            "endpoint": endpoint.isEmpty ? NSNull() as Any : endpoint as Any,
        ])
        self.username = username
        loginMessage = nil
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

    /// Sync with AnkiWeb, prompting for login if required. One-way syncs are
    /// never started here; they need the user's confirmation first.
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
                fullSyncPrompt = FullSyncPrompt(kind: .download, serverMediaUsn: result.serverMediaUsn)
            case "fullUpload":
                fullSyncPrompt = FullSyncPrompt(kind: .upload, serverMediaUsn: result.serverMediaUsn)
            case "fullSync":
                fullSyncPrompt = FullSyncPrompt(kind: .conflict, serverMediaUsn: result.serverMediaUsn)
            case "noChanges":
                monitorMediaSync()
            default:
                syncGeneration += 1
                monitorMediaSync()
            }
        } catch {
            handleSyncError(error)
        }
        await refresh()
    }

    /// Replace one side with the other, after the user confirmed it.
    func resolveFullSync(upload: Bool, serverMediaUsn: Int32?) async {
        guard let auth, !isSyncing else { return }
        isSyncing = true
        canAbortSync = true
        defer {
            isSyncing = false
            canAbortSync = false
        }
        do {
            try await backend.run([
                "cmd": "fullSync",
                "auth": auth.json,
                "upload": upload,
                "serverMediaUsn": serverMediaUsn.map { $0 as Any } ?? NSNull(),
            ])
            lastSync = Date()
            monitorMediaSync()
        } catch {
            handleSyncError(error)
        }
        // the collection was reopened, even if the sync failed
        syncGeneration += 1
        await refresh()
    }

    func abortSync() {
        backend.abortSync()
    }

    private func handleSyncError(_ error: Error) {
        if let error = error as? BackendError {
            if error.isInterrupted {
                return
            }
            if error.isAuthError {
                // explain on the login screen rather than in a second alert
                logout()
                loginMessage = error.message
                showLogin = true
                return
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
            // If a sync is already running, let it finish in the background.
            let task = BackgroundTask()
            task.id = UIApplication.shared.beginBackgroundTask(withName: "sync") { [backend] in
                // out of time: stop what can be stopped, and let iOS suspend us
                backend.abortSync()
                task.end()
            }
            Task {
                if isSyncing {
                    while isSyncing {
                        try? await Task.sleep(nanoseconds: 200_000_000)
                    }
                } else {
                    await sync()
                }
                task.end()
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

/// A background task identifier that can be ended exactly once, from either
/// the expiration handler or the normal completion path (both on the main thread).
@MainActor
private final class BackgroundTask {
    var id = UIBackgroundTaskIdentifier.invalid

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
