// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html

import SwiftUI

struct DeckListView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showAddNote = false
    @State private var showSettings = false

    var body: some View {
        List {
            Section {
                OutlineGroup(model.decks, children: \.childrenOrNil) { deck in
                    NavigationLink(value: deck) {
                        DeckRow(deck: deck)
                    }
                }
            } footer: {
                if !model.studiedToday.isEmpty {
                    Text(model.studiedToday)
                }
            }
        }
        .navigationTitle("Decks")
        .navigationDestination(for: DeckNode.self) { deck in
            StudyView(deck: deck, backend: model.backend, mediaFolder: model.paths.mediaFolder)
        }
        .refreshable {
            if model.isLoggedIn {
                await model.sync()
            } else {
                await model.refresh()
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
            }
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    showAddNote = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add Note")
                .disabled(!model.isOpen)
                SyncButton()
            }
        }
        .sheet(isPresented: $showAddNote) {
            AddNoteView()
                .environmentObject(model)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(model)
        }
        .overlay {
            if model.isOpen && model.decks.isEmpty {
                VStack(spacing: 12) {
                    Text("No decks yet.")
                        .font(.headline)
                    Text("Log in to AnkiWeb to download your collection, or add a note to get started.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
        }
    }
}

struct DeckRow: View {
    let deck: DeckNode

    var body: some View {
        HStack {
            Text(deck.name.components(separatedBy: "::").last ?? deck.name)
                .foregroundStyle(deck.filtered ? Color.blue : Color.primary)
            Spacer()
            HStack(spacing: 10) {
                countText(deck.new, .blue)
                countText(deck.learn, .red)
                countText(deck.review, .green)
            }
            .font(.callout.monospacedDigit())
        }
    }

    private func countText(_ value: Int, _ color: Color) -> some View {
        Text("\(value)")
            .foregroundStyle(value > 0 ? color : Color.secondary.opacity(0.5))
            .frame(minWidth: 24, alignment: .trailing)
    }
}

struct SyncButton: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if model.isSyncing {
            Button {
                model.abortSync()
            } label: {
                ProgressView()
            }
            .accessibilityLabel("Syncing")
        } else {
            Button {
                Task { await model.sync() }
            } label: {
                Image(systemName: model.isSyncingMedia ? "icloud.and.arrow.down" : "arrow.triangle.2.circlepath")
            }
            .accessibilityLabel("Sync")
            .disabled(!model.isOpen)
        }
    }
}
