import CerbosEmbeddedPDP
import SwiftUI

struct ContentView: View {
    @Environment(CerbosEmbeddedPDP.self) private var pdp

    @AppStorage(HubSettings.Key.ruleId) private var ruleId = HubSettings.defaultRuleId
    @AppStorage(HubSettings.Key.baseURL) private var hubBaseURL = ""
    @AppStorage(HubSettings.Key.clientId) private var clientId = ""
    @State private var clientSecret = Keychain.string(for: Keychain.clientSecretKey) ?? ""

    @State private var scenario = DemoScenario()
    @State private var lastResult: CheckResult?
    @State private var lastDuration: Duration?
    @State private var checkError: String?
    @State private var settingsError: String?
    @State private var isChecking = false
    @State private var showsHubSettings = false

    var body: some View {
        NavigationStack {
            Form {
                statusSection
                checkSection
                if !pdp.logs.isEmpty {
                    logsSection(pdp)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Cerbos ePDP")
            .navigationSubtitle(subtitle)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Cerbos Hub settings", systemImage: "slider.horizontal.3") {
                        showsHubSettings = true
                    }
                    .accessibilityIdentifier("hubSettingsButton")
                }
                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarItem(placement: .primaryAction) {
                    Menu("More", systemImage: "ellipsis") {
                        Button("Restart engine", systemImage: "arrow.clockwise") {
                            Task { await pdp.restart() }
                        }
                        .disabled(pdp.status == .loading)
                        Button("Clear offline cache", systemImage: "trash", role: .destructive) {
                            Task { await pdp.clearOfflineCache() }
                        }
                    }
                }
            }
            .sheet(isPresented: $showsHubSettings) {
                HubSettingsView(
                    ruleId: $ruleId, hubBaseURL: $hubBaseURL, clientId: $clientId, clientSecret: $clientSecret,
                    isLoading: pdp.status == .loading
                ) {
                    Task { await applySettings() }
                }
            }
        }
    }

    private var subtitle: String {
        if let server = pdp.server {
            return "Cerbos \(server.version) · rule \(ruleId)"
        }
        return "rule \(ruleId)"
    }

    // MARK: Sections

    @ViewBuilder
    private var statusSection: some View {
        Section {
            StatusBanner(status: pdp.status)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)

            if let bundle = pdp.bundle {
                LabeledContent("Bundle", value: bundle.bundleId)
                LabeledContent("Rule revision", value: bundle.ruleRevision)
                LabeledContent("Loaded from", value: bundle.source == .cache ? "Offline cache" : "Cerbos Hub")
                LabeledContent("Received", value: bundle.receivedAt.formatted(date: .omitted, time: .standard))
            }
            if let update = pdp.lastPolicyUpdate {
                LabeledContent("Last update check") {
                    HStack(spacing: 6) {
                        Image(systemName: update.succeeded ? "checkmark.circle" : "exclamationmark.triangle")
                            .foregroundStyle(update.succeeded ? .green : .orange)
                        Text(update.date.formatted(date: .omitted, time: .shortened))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if case .failed = pdp.status {
                Button("Try again", systemImage: "arrow.clockwise") {
                    Task { await pdp.start() }
                }
            }
            if let settingsError {
                Label(settingsError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.footnote)
            }
        } header: {
            Text("Embedded PDP")
        } footer: {
            Text(
                "Policies are downloaded from Cerbos Hub and evaluated on this device. The last bundle is cached so the app starts offline."
            )
        }
    }

    private var checkSection: some View {
        Section {
            LabeledContent("Principal") {
                TextField("Principal ID", text: $scenario.principalId)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Picker("Role", selection: $scenario.role) {
                ForEach(DemoScenario.roles, id: \.self) { Text($0) }
            }
            .pickerStyle(.segmented)
            Toggle("Principal owns the resource", isOn: $scenario.ownsResource)

            Button {
                Task { await runCheck() }
            } label: {
                HStack {
                    Label("Check access to \(DemoScenario.resourceKind) #1", systemImage: "checkmark.shield")
                    if isChecking {
                        Spacer()
                        ProgressView()
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .disabled(!pdp.isReady || isChecking)
            .accessibilityIdentifier("checkButton")
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .listRowBackground(Color.clear)

            if let checkError {
                Label(checkError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.footnote)
                    .accessibilityIdentifier("checkError")
            }

            if let lastResult {
                ForEach(DemoScenario.actions, id: \.self) { action in
                    EffectRow(
                        action: action, effect: lastResult.actions[action],
                        matchedPolicy: lastResult.metadata?.actions[action]?.matchedPolicy)
                }
                if let lastDuration {
                    Text(
                        "Evaluated locally in \(lastDuration.formatted(.units(allowed: [.milliseconds], fractionalPart: .show(length: 1))))"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("checkDuration")
                }
            }
        } header: {
            Text("Check")
        } footer: {
            Text("Runs checkResources against the loaded bundle. No network request is made for the decision.")
        }
    }

    private func logsSection(_ pdp: CerbosEmbeddedPDP) -> some View {
        Section("Recent activity") {
            ForEach(pdp.logs.suffix(15).reversed()) { line in
                VStack(alignment: .leading, spacing: 2) {
                    Text(line.message)
                        .font(.footnote.monospaced())
                        .foregroundStyle(line.level == .error ? .red : line.level == .warning ? .orange : .primary)
                    Text(line.date.formatted(date: .omitted, time: .standard))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Actions

    /// Reconfigures the shared PDP in place, reusing the compiled engine.
    private func applySettings() async {
        lastResult = nil
        checkError = nil
        settingsError = nil
        if clientSecret != (Keychain.string(for: Keychain.clientSecretKey) ?? "") {
            let status = Keychain.set(clientSecret, for: Keychain.clientSecretKey)
            if status != errSecSuccess {
                settingsError = "The client secret was not stored in the Keychain: \(Keychain.message(for: status))"
            }
        }
        await pdp.reconfigure(
            HubSettings.configuration(ruleId: ruleId, hubBaseURL: hubBaseURL, clientId: clientId, clientSecret: clientSecret))
    }

    private func runCheck() async {
        isChecking = true
        defer { isChecking = false }
        checkError = nil
        let clock = ContinuousClock()
        let started = clock.now
        do {
            let response = try await pdp.checkResources(scenario.request())
            lastDuration = clock.now - started
            lastResult = response.result(kind: DemoScenario.resourceKind, id: "1")
        } catch {
            checkError = error.localizedDescription
        }
    }
}

// MARK: - Hub settings

/// Validates the optional Hub base URL so a bad value is reported in the form, not as a start failure.
enum HubURLValidation {
    private static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]

    /// Returns a message naming the offending value, or `nil` when the text is empty or acceptable.
    static func problem(with text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), let host = url.host(), !host.isEmpty else {
            return "“\(trimmed)” is not a valid URL. Enter a full URL such as https://api.cerbos.cloud."
        }
        guard scheme == "https" || (scheme == "http" && loopbackHosts.contains(host.lowercased())) else {
            return "“\(trimmed)” must use https. Plain http is only allowed for localhost."
        }
        return nil
    }

    /// The URL to configure, or `nil` when the text is empty or invalid (the default Hub URL applies).
    static func url(from text: String) -> URL? {
        guard problem(with: text) == nil else { return nil }
        return URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

private struct HubSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var ruleId: String
    @Binding var hubBaseURL: String
    @Binding var clientId: String
    @Binding var clientSecret: String
    let isLoading: Bool
    let onApply: () -> Void

    @State private var urlError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Rule ID", text: $ruleId)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    TextField("Hub URL (default https://api.cerbos.cloud)", text: $hubBaseURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Embedded PDP rule")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Copy the rule ID from the deployment's Embedded PDP rules tab in Cerbos Hub.")
                        if let urlError {
                            Text(urlError).foregroundStyle(.red)
                        }
                        if isLoading {
                            Text("Wait for the current load to finish before applying changes.")
                        }
                    }
                }
                Section {
                    TextField("Client ID", text: $clientId)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Client secret", text: $clientSecret)
                } header: {
                    Text("Client credentials (optional)")
                } footer: {
                    Text("Only needed for rules with client-credential authentication. The secret is stored in the Keychain.")
                }
            }
            .navigationTitle("Cerbos Hub")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply", role: .confirm) {
                        if let problem = HubURLValidation.problem(with: hubBaseURL) {
                            urlError = problem
                            return
                        }
                        dismiss()
                        onApply()
                    }
                    .disabled(ruleId.trimmingCharacters(in: .whitespaces).isEmpty || isLoading)
                }
            }
            .onChange(of: hubBaseURL) { _, _ in urlError = nil }
        }
    }
}

// MARK: - Rows

private struct StatusBanner: View {
    let status: CerbosEmbeddedPDP.Status

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .accessibilityIdentifier("statusTitle")
                if let detail {
                    Text(detail).font(.footnote).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if case .loading = status {
                ProgressView()
            }
        }
        .padding()
        .glassEffect(.regular.tint(tint.opacity(0.15)), in: .rect(cornerRadius: 16))
    }

    private var symbol: String {
        switch status {
        case .idle: "pause.circle"
        case .loading: "arrow.triangle.2.circlepath.circle"
        case .ready: "checkmark.shield.fill"
        case .failed: "xmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch status {
        case .idle: .secondary
        case .loading: .blue
        case .ready: .green
        case .failed: .red
        }
    }

    private var title: String {
        switch status {
        case .idle: "Idle"
        case .loading: "Loading policies…"
        case .ready: "Ready"
        case .failed: "Failed"
        }
    }

    private var detail: String? {
        switch status {
        case .idle: nil
        case .loading: "Starting the engine and downloading the policy bundle"
        case .ready: "Decisions are evaluated on this device"
        case .failed(let error): error.localizedDescription
        }
    }
}

private struct EffectRow: View {
    let action: String
    let effect: Effect?
    let matchedPolicy: String?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(action)
                if let matchedPolicy {
                    Text(matchedPolicy)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            EffectBadge(effect: effect)
                .accessibilityIdentifier("effect-\(action)")
        }
    }
}

private struct EffectBadge: View {
    let effect: Effect?

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .glassEffect(.regular.tint(tint.opacity(0.2)))
            .accessibilityLabel(title)
    }

    private var title: String {
        switch effect {
        case .allow: "Allow"
        case .deny: "Deny"
        case nil: "No result"
        }
    }

    private var symbol: String {
        switch effect {
        case .allow: "checkmark"
        case .deny: "xmark"
        case nil: "minus"
        }
    }

    private var tint: Color {
        switch effect {
        case .allow: .green
        case .deny: .red
        case nil: .secondary
        }
    }
}

#Preview {
    ContentView()
        .environment(CerbosEmbeddedPDP(configuration: .init(ruleId: HubSettings.defaultRuleId)))
}
