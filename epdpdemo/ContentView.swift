import SwiftUI

struct ContentView: View {

    // Instantiate the service. Use @StateObject to keep it alive for the view's lifecycle.
    // Pass your actual Cerbos bundle URL here.
    @StateObject private var cerbosService = CerbosService(
        bundleURL: URL(string: "https://lite.cerbos.cloud/bundle?workspace=7SRBU5GTJZKS&label=f481a2c9c90ee3ae4deae7b7f656d65d1cd608828f5853d21e9ca383d479223a")!
    )

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                StatusView(isReady: cerbosService.isReady, error: cerbosService.lastError)

                Text("Check Result:")
                    .font(.headline)

                Text(cerbosService.lastCheckResultSummary)
                    .font(.system(.body, design: .monospaced))
                    .padding()
                    .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(8)

                Button("Perform Check") {
                    performCheck()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!cerbosService.isReady) // Disable button if PDP not ready

                // Optional: Add a retry button if there's an error
                if let error = cerbosService.lastError, !cerbosService.isReady {
                    Button("Retry Load") {
                        // Ensure you have the correct URL stored or accessible
                         cerbosService.retryLoad(bundleURL: URL(string: "https://lite.cerbos.cloud/bundle?workspace=7SRBU5GTJZKS&label=f481a2c9c90ee3ae4deae7b7f656d65d1cd608828f5853d21e9ca383d479223a")!)
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                }

                Spacer() // Push content to top
            }
            .padding()
            .navigationTitle("Cerbos PDP SwiftUI")
        }
    }

    func performCheck() {
         // Create the request object (same as before)
        let principalAttributes: [String: JSONValue] = [
            "department": .string("ux"),
            "region": .string("apac"),
            "device": .string("iphone")
        ]

        let settingsAttributes: [String: JSONValue] = [
            "requires_auth": .bool(true)
        ]

        let adminAttributes: [String: JSONValue] = [
            "access_level": .int(5)
        ]

        let request = CheckResourcesRequest(
            principal: Principal(
                id: "alice_swiftui",
                roles: ["user", "tester"],
                policyVersion: "default",
                scope: nil,
                attr: principalAttributes // Assign the correctly typed dictionary
            ),
            resources: [
                ResourceAction(
                    resource: Resource(
                        id: "settings_screen",
                        kind: "ui_screen",
                        policyVersion: "default",
                        scope: nil,
                        attr: settingsAttributes // Assign the correctly typed dictionary
                    ),
                    actions: ["view", "edit_profile"]
                ),
                ResourceAction(
                    resource: Resource(
                        id: "admin_dashboard",
                        kind: "ui_screen",
                        policyVersion: "default",
                        scope: nil,
                        attr: adminAttributes // Assign the correctly typed dictionary
                    ),
                    actions: ["view"]
                )
            ],
            includeMeta: false,
            auxData: nil
        )
        // Call the service method
        cerbosService.checkResources(request: request)
    }
}

// Helper View for Status Display
struct StatusView: View {
    let isReady: Bool
    let error: String?

    var body: some View {
        HStack {
            Image(systemName: isReady ? "checkmark.circle.fill" : (error == nil ? "hourglass" : "xmark.octagon.fill"))
                .foregroundColor(isReady ? .green : (error == nil ? .orange : .red))
            if isReady {
                Text("Cerbos PDP Ready")
                    .foregroundColor(.green)
            } else if let error = error {
                Text("Error: \(error)")
                    .foregroundColor(.red)
                    .lineLimit(10)
            } else {
                Text("Cerbos PDP Loading...")
                    .foregroundColor(.orange)
            }
            Spacer()
        }
        .padding(.vertical, 8)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}

