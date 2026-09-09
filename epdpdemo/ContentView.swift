import CerbosEmbeddedPDP
import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("cerbos.hub.ruleId") private var ruleId = "AVGB9RP6HFBL"
    @AppStorage("cerbos.hub.baseURL") private var hubBaseURL = ""
    @AppStorage("cerbos.hub.clientId") private var clientId = ""
    @State private var clientSecret = Keychain.string(for: Keychain.clientSecretKey) ?? ""

    @State private var pdp: CerbosEmbeddedPDP?
    @State private var scenario = DemoScenario()
    @State private var lastResult: CheckResult?
    @State private var lastDuration: Duration?
    @State private var checkError: String?
    @State private var isChecking = false

    var body: some View {
        NavigationStack {
            Form {
                hubSection
                statusSection
                checkSection
                if let pdp, !pdp.logs.isEmpty {
                    logsSection(pdp)
                }
            }
            .navigationTitle("Cerbos ePDP")
            .task {
                if pdp == nil {
                    await startPDP()
                }
            }
            .onChange(of: scenePhase) { _, phase in
                // WebKit can discard the content process in the background; recover on return.
                guard phase == .active, let pdp, case .failed = pdp.status else { return }
                Task { await pdp.start() }
            }
        }
    }

    // MARK: Sections

    private var hubSection: some View {
        Section {
            LabeledContent("Rule ID") {
                TextField("From the Embedded PDP rules tab", text: $ruleId)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
            }
            LabeledContent("Hub URL") {
                TextField("https://api.cerbos.cloud", text: $hubBaseURL)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            LabeledContent("Client ID") {
                TextField("Optional", text: $clientId)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            LabeledContent("Client secret") {
                SecureField("Optional", text: $clientSecret)
                    .multilineTextAlignment(.trailing)
            }
            Button(pdp == nil ? "Start" : "Restart with these settings") {
                Task { await startPDP() }
            }
            .disabled(ruleId.trimmingCharacters(in: .whitespaces).isEmpty || pdp?.status == .loading)
        } header: {
            Text("Cerbos Hub")
        } footer: {
            Text("Public rules need only the rule ID. Rules with client-credential authentication also need a client ID and secret (stored in the Keychain).")
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        Section("Embedded PDP") {
            if let pdp {
                StatusRow(status: pdp.status)
                if let bundle = pdp.bundle {
                    LabeledContent("Bundle", value: bundle.bundleId)
                    LabeledContent("Rule revision", value: bundle.ruleRevision)
                    LabeledContent("Loaded from", value: bundle.source == .cache ? "Offline cache" : "Cerbos Hub")
                    LabeledContent("Received", value: bundle.receivedAt.formatted(date: .omitted, time: .standard))
                }
                if let server = pdp.server {
                    LabeledContent("Engine", value: "Cerbos \(server.version)")
                }
                if let update = pdp.lastPolicyUpdate {
                    LabeledContent("Last update check") {
                        Text(update.succeeded ? "OK" : "Failed")
                            .foregroundStyle(update.succeeded ? .secondary : .red)
                        + Text(" · \(update.date.formatted(date: .omitted, time: .shortened))")
                            .foregroundStyle(.secondary)
                    }
                }
                Button("Clear offline cache", role: .destructive) {
                    Task { await pdp.clearOfflineCache() }
                }
            } else {
                Text("Not started").foregroundStyle(.secondary)
            }
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
            Toggle("Principal owns the resource", isOn: $scenario.ownsResource)

            Button {
                Task { await runCheck() }
            } label: {
                HStack {
                    Text("Check access to \(DemoScenario.resourceKind) #1")
                    if isChecking {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(pdp?.isReady != true || isChecking)

            if let checkError {
                Label(checkError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.footnote)
            }

            if let lastResult {
                ForEach(DemoScenario.actions, id: \.self) { action in
                    EffectRow(action: action, effect: lastResult.actions[action], matchedPolicy: lastResult.metadata?.actions[action]?.matchedPolicy)
                }
                if let lastDuration {
                    Text("Evaluated locally in \(lastDuration.formatted(.units(allowed: [.milliseconds], fractionalPart: .show(length: 1))))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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
                        .foregroundStyle(line.level == "error" ? .red : line.level == "warn" ? .orange : .primary)
                    Text(line.date.formatted(date: .omitted, time: .standard))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Actions

    private func startPDP() async {
        pdp?.stop()
        Keychain.set(clientSecret, for: Keychain.clientSecretKey)

        var configuration = CerbosEmbeddedPDP.Configuration(ruleId: ruleId)
        let trimmedURL = hubBaseURL.trimmingCharacters(in: .whitespaces)
        if !trimmedURL.isEmpty, let url = URL(string: trimmedURL) {
            configuration.hubBaseURL = url
        }
        let trimmedClientId = clientId.trimmingCharacters(in: .whitespaces)
        if !trimmedClientId.isEmpty, !clientSecret.isEmpty {
            configuration.credentials = .init(clientId: trimmedClientId, clientSecret: clientSecret)
        }

        let pdp = CerbosEmbeddedPDP(configuration: configuration)
        self.pdp = pdp
        lastResult = nil
        checkError = nil
        await pdp.start()
    }

    private func runCheck() async {
        guard let pdp else { return }
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

// MARK: - Rows

private struct StatusRow: View {
    let status: CerbosEmbeddedPDP.Status

    var body: some View {
        LabeledContent("Status") {
            switch status {
            case .idle:
                Text("Idle").foregroundStyle(.secondary)
            case .loading:
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Loading…")
                }
            case .ready:
                Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed(let error):
                Label(error.localizedDescription, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .font(.footnote)
            }
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
            switch effect {
            case .allow:
                Label("Allow", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .deny:
                Label("Deny", systemImage: "xmark.circle.fill").foregroundStyle(.red)
            case nil:
                Text("—").foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    ContentView()
}
