// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html

import SwiftUI

@main
struct AnkiApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .task { await model.start() }
        }
        .onChange(of: scenePhase) { phase in
            model.scenePhaseChanged(phase)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            DeckListView()
        }
        .sheet(isPresented: $model.showLogin) {
            LoginView()
                .environmentObject(model)
        }
        .alert(
            "Anki",
            isPresented: Binding(get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } }),
            presenting: model.alertMessage
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
        .confirmationDialog(
            "Your changes on this device and on AnkiWeb conflict. Which copy do you want to keep?",
            isPresented: Binding(get: { model.fullSyncPrompt != nil }, set: { if !$0 { model.fullSyncPrompt = nil } }),
            titleVisibility: .visible,
            presenting: model.fullSyncPrompt
        ) { prompt in
            Button("Keep AnkiWeb's (download)") {
                Task { await model.resolveFullSync(upload: false, serverMediaUsn: prompt.serverMediaUsn) }
            }
            Button("Keep this device's (upload)") {
                Task { await model.resolveFullSync(upload: true, serverMediaUsn: prompt.serverMediaUsn) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}
