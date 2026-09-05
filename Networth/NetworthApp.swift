import SwiftUI
import SwiftData
import BackgroundTasks
import UserNotifications
import UIKit
import os

public struct ReviewNotificationPreference: Equatable, Sendable {
    public let enabled: Bool
    public let denied: Bool

    public init(enabled: Bool, denied: Bool) {
        self.enabled = enabled
        self.denied = denied
    }
}

@MainActor
public protocol ReviewNotificationScheduling: Sendable {
    func preference() async -> ReviewNotificationPreference
    func setEnabled(_ enabled: Bool) async -> ReviewNotificationPreference
    func postNewReviewNotification(count: Int) async
}

@MainActor
public final class SystemReviewNotificationService:
    ReviewNotificationScheduling {
    private static let enabledKey =
        "networth.reviewNotificationsEnabled"
    static let routeKey = "networth.notificationRoute"
    static let reviewRoute = "transactionReview"
    private static let requestIdentifier =
        "networth.newTransactionReviews"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func preference() async -> ReviewNotificationPreference {
        let settings = await UNUserNotificationCenter.current()
            .notificationSettings()
        return ReviewNotificationPreference(
            enabled: defaults.bool(forKey: Self.enabledKey)
                && Self.isAuthorized(settings.authorizationStatus),
            denied: settings.authorizationStatus == .denied
        )
    }

    public func setEnabled(
        _ enabled: Bool
    ) async -> ReviewNotificationPreference {
        if enabled {
            let granted = (try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])) ?? false
            defaults.set(granted, forKey: Self.enabledKey)
        } else {
            defaults.set(false, forKey: Self.enabledKey)
            UNUserNotificationCenter.current().removePendingNotificationRequests(
                withIdentifiers: [Self.requestIdentifier]
            )
        }
        return await preference()
    }

    public func postNewReviewNotification(count: Int) async {
        guard count > 0, (await preference()).enabled else { return }
        let content = UNMutableNotificationContent()
        content.title = "Transactions ready to review"
        content.body = count == 1
            ? "1 new transaction needs your review."
            : "\(count) new transactions need your review."
        content.sound = .default
        content.userInfo = [Self.routeKey: Self.reviewRoute]
        let request = UNNotificationRequest(
            identifier: Self.requestIdentifier,
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    private static func isAuthorized(
        _ status: UNAuthorizationStatus
    ) -> Bool {
        switch status {
        case .authorized, .provisional, .ephemeral:
            true
        case .notDetermined, .denied:
            false
        @unknown default:
            false
        }
    }
}

@MainActor
public final class InMemoryReviewNotificationService:
    ReviewNotificationScheduling {
    public var currentPreference: ReviewNotificationPreference
    public var postedCounts: [Int] = []

    public init(
        enabled: Bool = false,
        denied: Bool = false
    ) {
        currentPreference = ReviewNotificationPreference(
            enabled: enabled,
            denied: denied
        )
    }

    public func preference() async -> ReviewNotificationPreference {
        currentPreference
    }

    public func setEnabled(
        _ enabled: Bool
    ) async -> ReviewNotificationPreference {
        currentPreference = ReviewNotificationPreference(
            enabled: enabled,
            denied: false
        )
        return currentPreference
    }

    public func postNewReviewNotification(count: Int) async {
        guard currentPreference.enabled, count > 0 else { return }
        postedCounts.append(count)
    }
}

enum NetworthBackgroundRefresh {
    static let identifier = "com.bluelava.me.networth.refresh"
    private static let logger = Logger(
        subsystem: "com.bluelava.me.networth",
        category: "background-refresh"
    )

    static func schedule(
        earliestBeginDate: Date = .now.addingTimeInterval(30 * 60)
    ) {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = earliestBeginDate
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            logger.error(
                "Background refresh scheduling failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}

enum ReviewNotificationRoute {
    private static let pendingKey =
        "networth.pendingTransactionReviewRoute"

    static func storePendingRequest(
        defaults: UserDefaults = .standard
    ) {
        defaults.set(true, forKey: pendingKey)
    }

    @discardableResult
    static func consumePendingRequest(
        defaults: UserDefaults = .standard
    ) -> Bool {
        let pending = defaults.bool(forKey: pendingKey)
        if pending {
            defaults.removeObject(forKey: pendingKey)
        }
        return pending
    }
}

@MainActor
final class NetworthAppDelegate: NSObject, UIApplicationDelegate,
    @MainActor UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions:
            [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        guard response.notification.request.content.userInfo[
            SystemReviewNotificationService.routeKey
        ] as? String == SystemReviewNotificationService.reviewRoute else {
            return
        }
        ReviewNotificationRoute.storePendingRequest()
        Task { @MainActor in
            NotificationCenter.default.post(
                name: .openTransactionReview,
                object: nil
            )
        }
    }
}

@main
struct NetworthApp: App {
    @UIApplicationDelegateAdaptor(NetworthAppDelegate.self)
    private var appDelegate
    @State private var container: AppContainerController
    @Environment(\.scenePhase) private var scenePhase
    @State private var bootstrapped: Bool = false
    @State private var isBootstrapping: Bool = false

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
                    guard scenePhase == .active else { return }
                    await bootstrapIfNeeded()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .active:
                        Task {
                            if container.bootstrapped {
                                container.refreshLinkedIBRLoan()
                                container.recordDailySnapshotOnActivation()
                                // Data refresh is owned by ContentView's single
                                // debounced trigger — a second immediate kick
                                // here defeated the post-launch settle delay.
                            } else {
                                await bootstrapIfNeeded()
                            }
                        }
                    case .background:
                        // Stamp the moment we lose the foreground so the
                        // biometric grace check on next bootstrap knows how
                        // long the app has been away.
                        container.markBackgrounded()
                        NetworthBackgroundRefresh.schedule()
                    case .inactive:
                        break
                    @unknown default:
                        break
                    }
                }
        }
        .backgroundTask(
            .appRefresh(NetworthBackgroundRefresh.identifier)
        ) {
            NetworthBackgroundRefresh.schedule()
            await container.performBackgroundRefresh()
        }
    }

    @MainActor
    private func bootstrapIfNeeded() async {
        guard !bootstrapped, !isBootstrapping,
              !Self.isHostingUnitTests else { return }
        isBootstrapping = true
        defer { isBootstrapping = false }
        await container.bootstrap()
        container.recordDailySnapshotOnActivation()
        NetworthBackgroundRefresh.schedule()
        bootstrapped = true
    }
}
