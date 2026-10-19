// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html

import SwiftUI

/// The app's top-level tabs. Later stages fill in the placeholders.
enum MainTab: String {
    case decks
    case browse
    case statistics
    case settings
}

/// Root of the interface: one NavigationStack per tab, so each tab keeps its
/// own navigation history when switching between them.
struct MainTabView: View {
    @EnvironmentObject private var model: AppModel
    @SceneStorage("mainTab") private var selection: MainTab = .decks

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack {
                DeckListView()
            }
            .tabItem { Label("Decks", systemImage: "rectangle.stack") }
            .tag(MainTab.decks)

            NavigationStack {
                BrowseTabView()
            }
            .tabItem { Label("Browse", systemImage: "magnifyingglass") }
            .tag(MainTab.browse)

            NavigationStack {
                StatisticsTabView()
            }
            .tabItem { Label("Statistics", systemImage: "chart.bar") }
            .tag(MainTab.statistics)

            SettingsTabView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(MainTab.settings)
        }
        .recordsLastSync(model)
    }
}

/// Placeholder: filled in at Stage 3 (T16 card browser).
struct BrowseTabView: View {
    var body: some View {
        TabPlaceholder(systemImage: "magnifyingglass", message: "The card browser will be added in Stage 3.")
            .navigationTitle("Browse")
    }
}

/// Placeholder: filled in at Stage 4 (T21), which will show the `graphs`
/// page through WebPageView.
struct StatisticsTabView: View {
    var body: some View {
        TabPlaceholder(systemImage: "chart.bar", message: "Statistics will be added in Stage 4.")
            .navigationTitle("Statistics")
    }
}

/// The Settings tab. SettingsView is designed as a sheet (its own
/// NavigationStack, a Done button and its own app presentations), so it is
/// still presented as a sheet from here rather than embedded in the tab.
/// Filled in at Stage 8 (T45 preferences screen).
struct SettingsTabView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showSyncSettings = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showSyncSettings = true
                    } label: {
                        HStack {
                            Label("Sync and Account", systemImage: "arrow.triangle.2.circlepath")
                                .foregroundStyle(Color.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                } header: {
                    Text("AnkiWeb")
                } footer: {
                    if model.isLoggedIn {
                        Text("Logged in as \(model.username)")
                    } else {
                        Text("Not logged in")
                    }
                }
                Section {
                    NavigationLink {
                        CollectionView()
                    } label: {
                        Label("Collection", systemImage: "externaldrive")
                    }
                } footer: {
                    Text("More preferences will be added in Stage 8.")
                }
            }
            .navigationTitle("Settings")
        }
        .sheet(isPresented: $showSyncSettings) {
            SettingsView()
                .environmentObject(model)
        }
    }
}

/// A centered icon and explanation, for tabs that a later stage fills in.
struct TabPlaceholder: View {
    let systemImage: String
    let message: LocalizedStringKey

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
