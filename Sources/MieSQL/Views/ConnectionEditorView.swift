import AppKit
import SwiftUI
import MieSQLCore

/// Create or edit a connection. Testing happens here so a profile is never saved blind.
struct ConnectionEditorView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var draft: ConnectionProfile
    @State private var password: String
    @State private var testState: TestState = .idle

    // Import from a connection string.
    @State private var urlText = ""
    @State private var urlStatus: URLStatus = .idle
    @State private var isURLSectionExpanded: Bool
    /// Guards the engine picker's onChange while a pasted URL replaces the whole draft.
    @State private var isApplyingURL = false

    enum TestState: Equatable {
        case idle
        case testing
        case success(String)
        case failure(String)
    }

    enum URLStatus: Equatable {
        case idle
        /// The clipboard held something that looks like a connection string.
        case suggested
        case applied(warnings: [String])
        case failed(String)
    }

    init(profile: ConnectionProfile, startInURLMode: Bool = false) {
        _draft = State(initialValue: profile)
        _password = State(initialValue: profile.savePassword
            ? (KeychainStore.password(account: profile.keychainAccount) ?? "")
            : "")
        _isURLSectionExpanded = State(initialValue: startInURLMode)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                urlSection

                Section(app.t("connection.section.general")) {
                    TextField(app.t("connection.name"), text: $draft.name, prompt: Text(app.t("connection.name.placeholder")))

                    Picker(app.t("connection.type"), selection: $draft.kind) {
                        ForEach(DatabaseKind.allCases) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .onChange(of: draft.kind) { _, newKind in
                        // Applying a URL replaces the whole draft, and the engine it names
                        // usually differs from the one on screen. That must not reset the
                        // port and user the URL just supplied.
                        guard !isApplyingURL else {
                            isApplyingURL = false
                            return
                        }
                        // Otherwise the user picked a different engine: keep the port and
                        // user sensible for it.
                        draft.port = newKind.defaultPort
                        if draft.username.isEmpty || DatabaseKind.allCases.contains(where: { $0.defaultUser == draft.username }) {
                            draft.username = newKind.defaultUser
                        }
                    }

                    if draft.kind.isFileBased {
                        HStack {
                            TextField(app.t("connection.file"), text: $draft.filePath)
                                .truncationMode(.head)
                            Button(app.t("general.browse")) { chooseFile() }
                        }
                    } else {
                        HStack {
                            TextField(app.t("connection.host"), text: $draft.host)
                            TextField(app.t("connection.port"), value: $draft.port, format: .number.grouping(.never))
                                .frame(width: 80)
                        }
                        TextField(app.t("connection.user"), text: $draft.username)
                        SecureField(app.t("connection.password"), text: $password)
                        TextField(app.t("connection.database"), text: $draft.database)
                    }
                }

                Section(app.t("connection.section.security")) {
                    if !draft.kind.isFileBased {
                        Picker(app.t("connection.ssl"), selection: $draft.sslMode) {
                            ForEach(SSLMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        Toggle(app.t("connection.savePassword"), isOn: $draft.savePassword)
                    }
                    Toggle(app.t("connection.readOnly"), isOn: $draft.readOnly)
                        .help(app.t("connection.readOnly.help"))
                    if !draft.kind.isFileBased {
                        TextField(app.t("connection.timeout"), value: $draft.connectTimeoutSeconds, format: .number)
                            .frame(width: 120)
                    }
                }

                Section(app.t("connection.section.appearance")) {
                    TextField(app.t("connection.folder"), text: $draft.folder, prompt: Text(app.t("connection.folder.placeholder")))
                    colorPicker
                    TextField(app.t("connection.notes"), text: $draft.notes, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            .formStyle(.grouped)

            Divider()
            footer
        }
        .frame(width: 480, height: 600)
        .onAppear(perform: offerClipboardURL)
    }

    // MARK: - Add from URL

    @ViewBuilder
    private var urlSection: some View {
        Section {
            DisclosureGroup(isExpanded: $isURLSectionExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField(app.t("connection.url"), text: $urlText, prompt: Text(app.t("connection.url.placeholder")), axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .font(.callout.monospaced())
                        .lineLimit(1...3)
                        .onSubmit(applyURL)

                    HStack(spacing: 8) {
                        Button(app.t("connection.url.apply"), action: applyURL)
                            .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Spacer()
                    }

                    switch urlStatus {
                    case .idle:
                        Text(app.t("connection.url.help"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    case .suggested:
                        Label(app.t("connection.url.fromClipboard"), systemImage: "doc.on.clipboard")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .applied(let warnings):
                        VStack(alignment: .leading, spacing: 4) {
                            Label(app.t("connection.url.applied"), systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                            // Anything understood but not honoured exactly is said out loud
                            // rather than quietly changing what the URL asked for.
                            ForEach(warnings, id: \.self) { warning in
                                Label(warning, systemImage: "exclamationmark.triangle")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    case .failed(let message):
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 4)
            } label: {
                Label(app.t("connection.url.section"), systemImage: "link")
            }
        }
    }

    private func applyURL() {
        do {
            let parsed = try ConnectionURLParser.parse(urlText)
            var profile = parsed.profile
            // Editing an existing connection keeps its identity, its folder and its colour;
            // only the details the URL actually carries are replaced.
            profile.id = draft.id
            profile.folder = draft.folder
            profile.colorHex = draft.colorHex
            profile.notes = draft.notes
            if !draft.name.isEmpty { profile.name = draft.name }

            isApplyingURL = profile.kind != draft.kind
            draft = profile
            if let parsedPassword = parsed.password {
                password = parsedPassword
            }
            urlStatus = .applied(warnings: parsed.warnings)
            testState = .idle
        } catch {
            urlStatus = .failed(error.localizedDescription)
        }
    }

    /// Offers the clipboard when it holds something that parses, which is how most people
    /// arrive here — straight from a hosting dashboard.
    private func offerClipboardURL() {
        guard isURLSectionExpanded, urlText.isEmpty else { return }
        guard let clipboard = NSPasteboard.general.string(forType: .string),
              ConnectionURLParser.looksLikeConnectionURL(clipboard) else { return }
        urlText = clipboard.trimmingCharacters(in: .whitespacesAndNewlines)
        urlStatus = .suggested
    }

    private var colorPicker: some View {
        HStack(spacing: 6) {
            Text(app.t("connection.color"))
            Spacer()
            Button {
                draft.colorHex = nil
            } label: {
                Circle()
                    .strokeBorder(Color.secondary, lineWidth: draft.colorHex == nil ? 2 : 1)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .help(app.t("general.none"))

            ForEach(Theme.connectionColors, id: \.hex) { entry in
                Button {
                    draft.colorHex = entry.hex
                } label: {
                    Circle()
                        .fill(Theme.color(hex: entry.hex) ?? .gray)
                        .frame(width: 16, height: 16)
                        .overlay(
                            Circle().strokeBorder(Color.primary, lineWidth: draft.colorHex == entry.hex ? 2 : 0)
                        )
                }
                .buttonStyle(.plain)
                .help(entry.name)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button(app.t("connection.test")) { test() }
                .disabled(testState == .testing || draft.validationError != nil)

            switch testState {
            case .idle:
                EmptyView()
            case .testing:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(app.t("connection.testing")).font(.caption)
                }
            case .success(let message):
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .lineLimit(2)
            case .failure(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .help(message)
            }

            Spacer()

            Button(app.t("general.cancel")) { dismiss() }
                .keyboardShortcut(.cancelAction)

            Button(app.t("general.save")) {
                app.save(profile: draft, password: password)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(draft.validationError != nil)
        }
        .padding(12)
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        // A new SQLite database is created on connect, so choosing a missing file is valid.
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft.filePath = url.path
        if draft.name.isEmpty {
            draft.name = url.deletingPathExtension().lastPathComponent
        }
    }

    private func test() {
        testState = .testing
        let profile = draft
        let secret = password
        Task {
            let result = await app.testConnection(profile, password: secret.isEmpty ? nil : secret)
            switch result {
            case .success(let info):
                testState = .success("\(app.t("connection.test.success")) \(info.productName) \(info.version)")
            case .failure(let error):
                testState = .failure(DatabaseSession.describe(error))
            }
        }
    }
}

/// Asked for when a connection has no saved password.
struct PasswordPromptView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    let request: PasswordRequest
    @State private var password = ""
    @State private var remember = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(request.profile.displayName)
                .font(.headline)
            Text(request.profile.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)

            SecureField(app.t("connection.password"), text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)

            Toggle(app.t("connection.savePassword"), isOn: $remember)

            HStack {
                Spacer()
                Button(app.t("general.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(app.t("connection.connect"), action: submit)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 340)
    }

    private func submit() {
        request.onSubmit(password, remember)
        dismiss()
    }
}
