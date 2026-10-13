// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmUpload = false
    @State private var confirmDownload = false
    @State private var showLogin = false
    @AppStorage("autoSync") private var autoSync = true
    @AppStorage("customSyncServer") private var customSyncServer = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("AnkiWeb") {
                    if model.isLoggedIn {
                        LabeledContent("Account", value: model.username)
                        Button("Sync Now") {
                            Task { await model.sync() }
                        }
                        .disabled(model.isSyncing)
                        Toggle("Sync automatically", isOn: $autoSync)
                        Button("Log Out", role: .destructive) {
                            model.logout()
                        }
                    } else {
                        Button("Log In") {
                            showLogin = true
                        }
                    }
                }
                if model.isLoggedIn {
                    Section {
                        Button("Upload to AnkiWeb (replace AnkiWeb)") { confirmUpload = true }
                        Button("Download from AnkiWeb (replace this device)") { confirmDownload = true }
                    } header: {
                        Text("One-Way Sync")
                    } footer: {
                        Text("Only needed to resolve problems. The other side's changes since the last sync will be lost.")
                    }
                    .disabled(model.isSyncing)
                }
                Section {
                    TextField("https://example.com/", text: $customSyncServer)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(model.isLoggedIn)
                } header: {
                    Text("Self-Hosted Sync Server")
                } footer: {
                    Text("Leave empty to use AnkiWeb. Log out to change.")
                }
                Section {
                    LabeledContent("Collection", value: model.paths.folder.lastPathComponent)
                } footer: {
                    Text("Your collection is stored in the app's Documents folder, accessible from the Files app.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showLogin) {
                LoginView()
                    .environmentObject(model)
            }
            .confirmationDialog("Replace AnkiWeb's copy with this device's collection?", isPresented: $confirmUpload, titleVisibility: .visible) {
                Button("Upload", role: .destructive) {
                    Task { await model.resolveFullSync(upload: true, serverMediaUsn: nil) }
                }
            }
            .confirmationDialog("Replace this device's collection with AnkiWeb's copy?", isPresented: $confirmDownload, titleVisibility: .visible) {
                Button("Download", role: .destructive) {
                    Task { await model.resolveFullSync(upload: false, serverMediaUsn: nil) }
                }
            }
        }
    }
}
