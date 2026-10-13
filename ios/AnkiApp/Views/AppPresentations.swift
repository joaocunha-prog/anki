// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html

import SwiftUI

extension View {
    /// Shows the app-wide alerts, sync prompts and login screen. Applied to the
    /// root view and to each sheet, as a view that is covered by a sheet
    /// cannot present anything itself.
    func appPresentations(_ model: AppModel) -> some View {
        modifier(AppPresentations(model: model))
    }
}

private struct AppPresentations: ViewModifier {
    @ObservedObject var model: AppModel

    func body(content: Content) -> some View {
        content
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
                title(for: model.fullSyncPrompt?.kind),
                isPresented: Binding(get: { model.fullSyncPrompt != nil }, set: { if !$0 { model.fullSyncPrompt = nil } }),
                titleVisibility: .visible,
                presenting: model.fullSyncPrompt
            ) { prompt in
                if prompt.kind != .upload {
                    Button("Keep AnkiWeb's (download)") {
                        Task { await model.resolveFullSync(upload: false, serverMediaUsn: prompt.serverMediaUsn) }
                    }
                }
                if prompt.kind != .download {
                    Button("Keep this device's (upload)") {
                        Task { await model.resolveFullSync(upload: true, serverMediaUsn: prompt.serverMediaUsn) }
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
    }

    private func title(for kind: FullSyncPrompt.Kind?) -> LocalizedStringKey {
        switch kind {
        case .download:
            return "This device has no cards. Replace it with your AnkiWeb collection?"
        case .upload:
            return "AnkiWeb has no cards. Replace it with this device's collection?"
        default:
            return "Your changes on this device and on AnkiWeb conflict. Which copy do you want to keep?"
        }
    }
}
