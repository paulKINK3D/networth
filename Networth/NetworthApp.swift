import SwiftUI
import SwiftData

@main
struct NetworthApp: App {
    @State private var container: AppContainerController
    @Environment(\.scenePhase) private var scenePhase
    @State private var bootstrapped: Bool = false

    init() {
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
                    if !bootstrapped {
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
