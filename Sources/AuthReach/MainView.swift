import AuthReachCore
import KeyboardShortcuts
import ServiceManagement
import SwiftUI

struct MainView: View {
    @ObservedObject var model: AppModel
    @State private var showCredentialsSheet = false

    var body: some View {
        Form {
            accountsSection
            recentSection
            preferencesSection
            localApiSection
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 620)
        .sheet(isPresented: $showCredentialsSheet) {
            CredentialsSheet(model: model, isPresented: $showCredentialsSheet)
        }
        .overlay(alignment: .bottom) {
            if let notice = model.notice {
                Text(notice)
                    .font(.caption).lineLimit(2)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                    .padding(.bottom, 12)
                    .task {
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        model.notice = nil
                    }
            }
        }
    }

    private var accountsSection: some View {
        Section("Accounts") {
            if model.settings.accounts.isEmpty {
                Text("No inboxes connected yet.").foregroundStyle(.secondary)
            }
            ForEach(model.settings.accounts) { account in
                HStack {
                    Image(systemName: "envelope").foregroundStyle(.secondary)
                    Text(account.email)
                    Spacer()
                    if let error = model.accountStatus[account.id], !error.isEmpty {
                        Text(error).font(.caption).foregroundStyle(.red)
                            .lineLimit(1).truncationMode(.tail)
                            .help(error)
                    } else {
                        Text("OK").font(.caption).foregroundStyle(.green)
                    }
                    Button(role: .destructive) {
                        model.disconnect(account: account)
                    } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Disconnect \(account.email)")
                }
            }
            HStack {
                Button("Add Google account…") { model.addGoogleAccount() }
                    .disabled(!model.googleCredentialsSet)
                Spacer()
                Button(model.googleCredentialsSet ? "Google API credentials…" : "Set up Google API credentials…") {
                    showCredentialsSheet = true
                }
                .buttonStyle(.link)
            }
            if !model.googleCredentialsSet {
                Text("AuthReach uses your own Google OAuth client (Desktop type, Gmail API enabled, scope gmail.readonly). One client authorizes all your accounts.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var recentSection: some View {
        Section("Recent codes") {
            if model.recent.isEmpty {
                Text("Codes from your inboxes appear here.").foregroundStyle(.secondary)
            }
            ForEach(model.recent.prefix(8)) { entry in
                Button { model.copyEntry(entry) } label: {
                    HStack {
                        Text(entry.code).font(.body.monospaced().weight(.semibold))
                        VStack(alignment: .leading, spacing: 0) {
                            Text(model.settings.accounts.count > 1
                                 ? "\(entry.service) · \(entry.accountEmail)" : entry.service)
                                .font(.caption)
                            Text(relativeTime(entry.receivedAt))
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        if let expiry = expiryLabel(entry.expiresAt) {
                            Text(expiry.label)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(expiry.expired ? .red : expiry.urgent ? .orange : .secondary)
                        }
                        Image(systemName: "doc.on.doc").font(.caption).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var preferencesSection: some View {
        Section("Preferences") {
            KeyboardShortcuts.Recorder("Code HUD shortcut:", name: .toggleHud)
            LaunchAtLoginToggle()
            Toggle("Copy new codes automatically", isOn: binding(\.autoCopy))
            Toggle("Notify when a code arrives", isOn: binding(\.notify))
            Picker("Check inboxes every", selection: binding(\.pollIntervalSec)) {
                Text("10 seconds").tag(10)
                Text("15 seconds").tag(15)
                Text("30 seconds").tag(30)
                Text("60 seconds").tag(60)
            }
        }
    }

    private var localApiSection: some View {
        Section {
            Toggle("Enable local API", isOn: binding(\.localApiEnabled))
            if model.settings.localApiEnabled {
                TextField("Port", value: binding(\.localApiPort), format: .number.grouping(.never))
                    .frame(width: 220)
                Toggle("Include sender/subject/account in responses", isOn: binding(\.localApiExposeMetadata))
                HStack {
                    Text(model.settings.localApiToken.isEmpty ? "token pending…" : model.settings.localApiToken)
                        .font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Button { model.copy(model.settings.localApiToken); model.notice = "Token copied" }
                        label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless).accessibilityLabel("Copy token")
                    Button { model.regenerateApiToken() }
                        label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).accessibilityLabel("Regenerate token")
                }
                Text("GET http://localhost:\(String(model.settings.localApiPort))/v1/otps/latest[/code] — filter with ?service=&sender=&accountEmail=&maxAgeSeconds=")
                    .font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                if let error = model.localApiError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        } header: {
            Text("Local API")
        } footer: {
            Text("Loopback-only; every request needs the bearer token.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<AuthReachCore.Settings, T>) -> Binding<T> {
        Binding(get: { model.settings[keyPath: keyPath] },
                set: { newValue in model.updateSettings { $0[keyPath: keyPath] = newValue } })
    }
}

struct CredentialsSheet: View {
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool
    @State private var clientId = ""
    @State private var clientSecret = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Google API credentials").font(.headline)
            Text("Create an OAuth client (type: Desktop app) in the Google Cloud console with the Gmail API enabled, then paste its ID and secret. They are stored in your Keychain.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Client ID", text: $clientId)
                .textFieldStyle(.roundedBorder).font(.caption.monospaced())
            SecureField("Client secret", text: $clientSecret)
                .textFieldStyle(.roundedBorder).font(.caption.monospaced())
            HStack {
                Link("Open Google Cloud console",
                     destination: URL(string: "https://console.cloud.google.com/apis/credentials")!)
                    .font(.caption)
                Spacer()
                Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.saveGoogleCredentials(clientId: clientId, clientSecret: clientSecret)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(clientId.isEmpty || clientSecret.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 440)
    }
}


struct LaunchAtLoginToggle: View {
    @State private var enabled = SMAppService.mainApp.status == .enabled
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle("Launch at login", isOn: $enabled)
                .onChange(of: enabled) { newValue in
                    do {
                        if newValue { try SMAppService.mainApp.register() }
                        else { try SMAppService.mainApp.unregister() }
                        error = nil
                    } catch {
                        self.error = error.localizedDescription
                        enabled = SMAppService.mainApp.status == .enabled
                    }
                }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }
}
