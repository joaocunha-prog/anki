// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html

import SwiftUI

/// A simple plain-text note editor.
struct AddNoteView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var notetypes: [NotetypeInfo] = []
    @State private var decks: [DeckName] = []
    @State private var notetypeId: Int64 = 0
    @State private var deckId: Int64 = 0
    @State private var fields: [String] = []
    @State private var tags = ""
    @State private var errorMessage: String?
    @State private var addedCount = 0

    private var notetype: NotetypeInfo? {
        notetypes.first { $0.id == notetypeId }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $notetypeId) {
                        ForEach(notetypes) { Text($0.name).tag($0.id) }
                    }
                    Picker("Deck", selection: $deckId) {
                        ForEach(decks) { Text($0.name).tag($0.id) }
                    }
                }
                if let notetype {
                    Section {
                        ForEach(Array(notetype.fields.enumerated()), id: \.offset) { index, name in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(name)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                TextField(name, text: fieldBinding(index), axis: .vertical)
                                    .lineLimit(1 ... 8)
                            }
                        }
                    } footer: {
                        if notetype.name.lowercased().contains("cloze") {
                            Text("Use {{c1::text}} to create cloze deletions.")
                        }
                    }
                }
                Section("Tags") {
                    TextField("Space-separated tags", text: $tags)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                if addedCount > 0 {
                    Section {
                        Label("Added \(addedCount) notes.", systemImage: "checkmark.circle")
                            .foregroundStyle(.green)
                    }
                }
            }
            .navigationTitle("Add Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await add() } }
                        .disabled(fields.first?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                }
            }
            .onChange(of: notetypeId) { _ in
                fields = Array(repeating: "", count: notetype?.fields.count ?? 0)
            }
            .alert(
                "Error",
                isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }),
                presenting: errorMessage
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { message in
                Text(message)
            }
            .task { await load() }
        }
    }

    private func fieldBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { fields.indices.contains(index) ? fields[index] : "" },
            set: { if fields.indices.contains(index) { fields[index] = $0 } }
        )
    }

    private func load() async {
        do {
            notetypes = try await model.backend.call([NotetypeInfo].self, ["cmd": "notetypes"])
            decks = try await model.backend.call([DeckName].self, ["cmd": "deckNames"])
            let defaults = try await model.backend.call(AddDefaults.self, ["cmd": "addDefaults"])
            deckId = defaults.deckId
            notetypeId = defaults.notetypeId
            fields = Array(repeating: "", count: notetype?.fields.count ?? 0)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func add() async {
        do {
            try await model.backend.run([
                "cmd": "addNote",
                "notetypeId": notetypeId,
                "deckId": deckId,
                "fields": fields.map(Self.plainTextToHtml),
                "tags": tags.split(separator: " ").map(String.init),
            ])
            addedCount += 1
            fields = Array(repeating: "", count: fields.count)
            await model.refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Fields are stored as HTML, so escape what the user typed.
    static func plainTextToHtml(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: "<br>")
    }
}
