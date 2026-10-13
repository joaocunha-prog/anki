// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html

import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var password = ""
    @State private var loggingIn = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Email", text: $username)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                } header: {
                    Text("AnkiWeb Account")
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Your collection will be synced with AnkiWeb, so you can study on your other devices too.")
                        Link("Create a free account", destination: URL(string: "https://ankiweb.net/account/signup")!)
                        if !model.customSyncServer.isEmpty {
                            Text("Using custom sync server: \(model.customSyncServer)")
                        }
                    }
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
                Section {
                    Button {
                        Task { await login() }
                    } label: {
                        HStack {
                            Spacer()
                            if loggingIn {
                                ProgressView()
                            } else {
                                Text("Log In").bold()
                            }
                            Spacer()
                        }
                    }
                    .disabled(username.isEmpty || password.isEmpty || loggingIn)
                }
            }
            .navigationTitle("Log In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if loggingIn {
                            model.abortSync()
                        }
                        dismiss()
                    }
                }
            }
            .onAppear {
                if username.isEmpty {
                    username = model.username
                }
            }
        }
    }

    private func login() async {
        loggingIn = true
        errorMessage = nil
        defer { loggingIn = false }
        do {
            try await model.login(
                username: username.trimmingCharacters(in: .whitespaces),
                password: password
            )
            dismiss()
        } catch let error as BackendError where error.isInterrupted {
            // cancelled
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
