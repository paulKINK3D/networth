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
                        container.recordDailySnapshot()
                        bootstrapped = true
                    }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        container.recordDailySnapshot()
                    }
                }
        }
    }
}
