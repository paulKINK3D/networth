import SwiftUI
import SwiftData

@main
struct NetworthApp: App {
    @State private var container: AppContainerController
    @Environment(\.scenePhase) private var scenePhase
    @State private var bootstrapped: Bool = false

    /// True when the app is merely hosting a unit-test run. The host app must
    /// never bootstrap then: bootstrap performs real work against the real
    /// store — including the destructive Plaid-first clean start — and a ⌘U
    /// on a physical device would otherwise reset live data.
    private static let isHostingUnitTests =
        NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestSessionIdentifier"] != nil

    init() {
        if Self.isHostingUnitTests {
            // Tests build their own in-memory containers; the host app stays
            // inert on a placeholder container that never touches disk.
            _container = State(initialValue: AppContainerController.makePreview())
            return
        }
        let production: AppContainerController
        do {
            production = try AppContainerController.makeProduction()
        } catch {
            assertionFailure("Failed to build production container: \(error)")
            production = AppContainerController.makePreview()
        }
        _container = State(initialValue: production)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(container)
                .modelContainer(container.modelContainer)
                .task {
                    if !bootstrapped && !Self.isHostingUnitTests {
                        await container.bootstrap()
                        container.recordDailySnapshotOnActivation()
                        bootstrapped = true
                    }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .active:
                        container.refreshLinkedIBRLoan()
                        container.recordDailySnapshotOnActivation()
                        // Data refresh is owned by ContentView's single
                        // debounced trigger — a second immediate kick here
                        // defeated the post-launch settle delay.
                    case .background:
                        // Stamp the moment we lose the foreground so the
                        // biometric grace check on next bootstrap knows how
                        // long the app has been away.
                        container.markBackgrounded()
                    case .inactive:
                        break
                    @unknown default:
                        break
                    }
                }
        }
    }
}
