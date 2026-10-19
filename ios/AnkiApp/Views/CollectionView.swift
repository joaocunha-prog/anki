// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html

import SwiftUI

/// Information about the open collection: where it lives, how large it is,
/// how many decks it has and when it was last synced.
struct CollectionView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(LastSyncRecord.defaultsKey) private var lastSyncTimestamp: Double = 0
    @State private var files: CollectionFileInfo?

    var body: some View {
        Form {
            Section {
                LabeledContent("Folder", value: model.paths.folder.lastPathComponent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Path")
                    Text(model.paths.collection.path)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                LabeledContent("File Size") {
                    if let files {
                        if let bytes = files.collectionBytes {
                            Text(Self.format(bytes: bytes))
                        } else {
                            Text("Unknown")
                        }
                    } else {
                        Text("Calculating…")
                    }
                }
                LabeledContent("Media Files") {
                    if let files {
                        Text("\(files.mediaFiles) files (\(Self.format(bytes: files.mediaBytes)))")
                    } else {
                        Text("Calculating…")
                    }
                }
            } header: {
                Text("Storage")
            } footer: {
                Text("Your collection is stored in the app's Documents folder, accessible from the Files app.")
            }

            Section {
                if model.isOpen {
                    LabeledContent("Decks", value: "\(Self.deckCount(model.decks))")
                    LabeledContent("Due Today", value: "\(Self.dueCount(model.decks))")
                } else {
                    Text("The collection is not open.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Contents")
            } footer: {
                if !model.studiedToday.isEmpty {
                    Text(model.studiedToday)
                }
            }

            Section {
                LabeledContent("Account") {
                    if model.isLoggedIn {
                        Text(model.username)
                    } else {
                        Text("Not logged in")
                    }
                }
                LabeledContent("Last Sync") {
                    if lastSyncTimestamp > 0 {
                        Text(Date(timeIntervalSince1970: lastSyncTimestamp).formatted(date: .abbreviated, time: .shortened))
                    } else {
                        Text("Never")
                    }
                }
            } header: {
                Text("AnkiWeb")
            } footer: {
                Text("Last sync is the last one completed on this device without errors.")
            }
        }
        .navigationTitle("Collection")
        .navigationBarTitleDisplayMode(.inline)
        // reload after a sync, which may have replaced the collection or added media
        .task(id: model.syncGeneration) {
            let paths = model.paths
            files = await Task.detached(priority: .utility) {
                CollectionFileInfo.load(paths)
            }.value
        }
    }

    private static func format(bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// All decks, including subdecks.
    static func deckCount(_ nodes: [DeckNode]) -> Int {
        nodes.reduce(0) { $0 + 1 + deckCount($1.children) }
    }

    /// Cards due today. Each top-level deck's counts already include its
    /// subdecks (within the deck limits), so only the top level is summed.
    static func dueCount(_ nodes: [DeckNode]) -> Int {
        nodes.reduce(0) { $0 + $1.new + $1.learn + $1.review }
    }
}

/// Sizes of the collection file and media folder, read off the main thread.
struct CollectionFileInfo {
    var collectionBytes: Int64?
    var mediaFiles = 0
    var mediaBytes: Int64 = 0

    static func load(_ paths: CollectionPaths) -> CollectionFileInfo {
        let fileManager = FileManager.default
        var info = CollectionFileInfo()
        if let attributes = try? fileManager.attributesOfItem(atPath: paths.collection.path),
           let size = attributes[.size] as? NSNumber
        {
            info.collectionBytes = size.int64Value
        }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        if let urls = try? fileManager.contentsOfDirectory(
            at: paths.mediaFolder,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) {
            for url in urls {
                guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true
                else { continue }
                info.mediaFiles += 1
                info.mediaBytes += Int64(values.fileSize ?? 0)
            }
        }
        return info
    }
}

/// AppModel keeps the time of the last sync private, so the time of the last
/// sync that finished without errors is recorded here, from the outside.
/// Approximate: a sync interrupted by the user is also counted. Can be
/// replaced once AppModel exposes its last sync time.
enum LastSyncRecord {
    static let defaultsKey = "lastSyncDate"
}

extension View {
    /// Records the time whenever a sync finishes without errors or prompts.
    /// Applied once, to the root of the interface.
    func recordsLastSync(_ model: AppModel) -> some View {
        modifier(LastSyncRecorder(model: model))
    }
}

private struct LastSyncRecorder: ViewModifier {
    @ObservedObject var model: AppModel
    @AppStorage(LastSyncRecord.defaultsKey) private var lastSyncTimestamp: Double = 0

    func body(content: Content) -> some View {
        content
            .onChange(of: model.isSyncing) { syncing in
                // a failed sync leaves an alert (or logs out on an auth error);
                // a sync that needs confirmation leaves a one-way sync prompt
                guard !syncing, model.isLoggedIn, model.alertMessage == nil, model.fullSyncPrompt == nil
                else { return }
                lastSyncTimestamp = Date().timeIntervalSince1970
            }
    }
}
