import AuthReachCore
import KeyboardShortcuts
import ServiceManagement
import SwiftUI

struct MainView: View {
    @ObservedObject var model: AppModel
    @State private var showCredentialsSheet = false
    @State private var showImapSheet = false

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
        .sheet(isPresented: $showImapSheet) {
            ImapAccountSheet(model: model, isPresented: $showImapSheet)
        }
        .overlay(alignment: .bottom) {
            if let notice = model.notice {
                NoticeBanner(notice: notice) { model.notice = nil }
                    .padding(.horizontal, 16).padding(.bottom, 12)
                    // Keyed by id, so a newer notice gets its own full delay.
                    .task(id: notice.id) {
                        guard !notice.isError else { return }
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        if model.notice?.id == notice.id { model.notice = nil }
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
                    Text(account.provider == .google ? "Gmail" : "IMAP")
                        .font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                    if let error = model.accountStatus[account.id], !error.isEmpty {
                        Text(error).font(.caption).foregroundStyle(.red)
                            .lineLimit(2).truncationMode(.tail)
                            .help(error)
                        if account.provider == .google {
                            Button("Reconnect") { model.addGoogleAccount() }
                                .controlSize(.small)
                                .disabled(model.googleSignInPending)
                                .help("Sign in to \(account.email) again in your browser")
                        }
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
            if model.googleSignInPending {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Waiting for Google sign-in in your browser…")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { model.cancelGoogleSignIn() }.controlSize(.small)
                }
            }
            HStack {
                Button("Add Google account…") { model.addGoogleAccount() }
                    .disabled(!model.googleCredentialsSet || model.googleSignInPending)
                Button("Add IMAP account…") { showImapSheet = true }
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
                    Button { model.copy(model.settings.localApiToken); model.inform("Token copied") }
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

    private var credentials: GoogleCredentials {
        GoogleCredentials(pastedClientId: clientId, clientSecret: clientSecret)
    }

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
            // Only once both are filled in, so it doesn't nag while typing.
            if !clientId.isEmpty, !clientSecret.isEmpty, let problem = credentials.problem {
                Text(problem).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Link("Open Google Cloud console",
                     destination: URL(string: "https://console.cloud.google.com/apis/credentials")!)
                    .font(.caption)
                Spacer()
                Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.saveGoogleCredentials(credentials)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(credentials.problem != nil)
            }
        }
        .padding(16)
        .frame(width: 440)
    }
}

/// The bottom-of-window notice. Errors get an icon, wrap instead of
/// truncating, can be selected (to paste into a search or a bug report),
/// and have a close button since they don't time out.
struct NoticeBanner: View {
    let notice: Notice
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if notice.isError {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            Text(notice.text)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if notice.isError {
                Button(action: dismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).font(.caption)
                    .accessibilityLabel("Dismiss")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(notice.isError ? AnyShapeStyle(.red.opacity(0.5)) : AnyShapeStyle(.quaternary)))
    }
}

/// Generic IMAP account: host/port/username/password, verified against the
/// server before being stored in the Keychain.
struct ImapAccountSheet: View {
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool
    @State private var email = ""
    @State private var host = ""
    @State private var port = 993
    @State private var username = ""
    @State private var password = ""
    @State private var isConnecting = false
    @State private var error: String?
    @State private var connectTask: Task<Void, Never>?

    /// Hosts for common providers, filled in from the address domain.
    private static let knownHosts: [String: String] = [
        "gmail.com": "imap.gmail.com", "googlemail.com": "imap.gmail.com",
        "icloud.com": "imap.mail.me.com", "me.com": "imap.mail.me.com", "mac.com": "imap.mail.me.com",
        "fastmail.com": "imap.fastmail.com", "fastmail.fm": "imap.fastmail.com",
        "yahoo.com": "imap.mail.yahoo.com", "yahoo.se": "imap.mail.yahoo.com",
        "gmx.com": "imap.gmx.com", "gmx.de": "imap.gmx.net", "gmx.net": "imap.gmx.net",
    ]

    private var canConnect: Bool {
        !email.isEmpty && !host.isEmpty && !password.isEmpty && (1...65535).contains(port) && !isConnecting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add IMAP account").font(.headline)
            Text("Works with any IMAP server over TLS (port 993). Use an app-specific password where your provider requires one (Gmail, iCloud, Yahoo). Credentials are stored in your Keychain; the inbox is opened read-only.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Email")
                    TextField("you@example.com", text: $email)
                        .onChange(of: email) { _ in suggestHost() }
                }
                GridRow {
                    Text("Server")
                    HStack {
                        TextField("imap.example.com", text: $host)
                        TextField("Port", value: $port, format: .number.grouping(.never))
                            .frame(width: 64)
                    }
                }
                GridRow {
                    Text("Username")
                    TextField("Same as email", text: $username)
                }
                GridRow {
                    Text("Password")
                    SecureField("App password", text: $password)
                }
            }
            .textFieldStyle(.roundedBorder)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if isConnecting { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") {
                    connectTask?.cancel()
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Connect") { connect() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canConnect)
            }
        }
        .padding(16)
        .frame(width: 460)
    }

    private func suggestHost() {
        guard host.isEmpty, let at = email.lastIndex(of: "@") else { return }
        let domain = email[email.index(after: at)...].lowercased()
        if let known = Self.knownHosts[domain] { host = known }
    }

    private func connect() {
        error = nil
        isConnecting = true
        let trimmedEmail = email.trimmingCharacters(in: .whitespaces)
        let credentials = ImapCredentials(
            host: host.trimmingCharacters(in: .whitespaces),
            port: port,
            username: username.isEmpty ? trimmedEmail : username.trimmingCharacters(in: .whitespaces),
            password: password)
        connectTask = Task {
            do {
                try await model.addImapAccount(email: trimmedEmail, credentials: credentials)
                isPresented = false
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
            isConnecting = false
        }
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
