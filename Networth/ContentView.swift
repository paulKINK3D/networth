import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(AppContainerController.self) private var container
    @Query private var userSettings: [DurableUserSettings]
    @State private var selection: Int = 0
    @State private var alertPayload: PersistenceFailure?
    @State private var showingTutorial = false
    @State private var showingSettings = false
    /// Minimum hold time for the launch splash so it always shows long enough
    /// to read — matches the WorkoutApp splash pause (1.2 s) before fading.
    @State private var splashMinimumElapsed = false

    var body: some View {
        ZStack {
            if !container.bootstrapped || !splashMinimumElapsed {
                SplashView()
                    .transition(.opacity)
            } else if container.unlocked {
                tabs
                    .transition(.opacity)
            } else {
                LockedView()
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.25), value: container.unlocked)
        .animation(.easeOut(duration: 0.25), value: container.bootstrapped)
        .animation(.easeOut(duration: 0.25), value: splashMinimumElapsed)
        .task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            splashMinimumElapsed = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectTab)) { note in
            if let tab = note.object as? Int { selection = tab }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
            showingSettings = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .showTutorial)) { _ in
            showingTutorial = true
        }
        .onChange(of: container.lastPersistenceError) { _, new in
            alertPayload = new
        }
        .onChange(of: container.unlocked) { _, isUnlocked in
            if isUnlocked, !(userSettings.first?.hasSeenTutorial ?? false) {
                showingTutorial = true
            }
        }
        .task {
            if container.unlocked, !(userSettings.first?.hasSeenTutorial ?? false) {
                showingTutorial = true
            }
        }
        .sheet(isPresented: $showingTutorial) {
            TutorialView().environment(container)
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                SettingsView()
                    .environment(container)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showingSettings = false }
                        }
                    }
            }
        }
        .alert("Save failed",
               isPresented: Binding(get: { alertPayload != nil }, set: { if !$0 { alertPayload = nil } })) {
            Button("OK", role: .cancel) { alertPayload = nil }
        } message: {
            Text(alertPayload?.message ?? "")
        }
    }

    private var tabs: some View {
        TabView(selection: $selection) {
            NetWorthView()
                .tabItem { Label("Net Worth", systemImage: NwIcon.netWorth.rawValue) }
                .tag(0)
            ProjectionsView()
                .tabItem { Label("Projections", systemImage: NwIcon.projections.rawValue) }
                .tag(1)
            AccountsView()
                .tabItem { Label("Accounts", systemImage: NwIcon.accounts.rawValue) }
                .tag(2)
            InvestmentsView()
                .tabItem { Label("Investments", systemImage: NwIcon.investment.rawValue) }
                .tag(3)
        }
        .tint(NwAppColors.primary)
    }
}

/// Brand gradient used for both the launch splash and the locked screen so
/// the transition between them never flashes the system grouped background
/// (which is the off-white the user was seeing between splash and unlock).
enum BlueLavaSplash {
    static let gradient = LinearGradient(
        gradient: Gradient(stops: [
            .init(color: Color(red: 0x1E/255, green: 0x3A/255, blue: 0x8A/255), location: 0.0),
            .init(color: Color(red: 0x1B/255, green: 0x2F/255, blue: 0x6F/255), location: 0.5),
            .init(color: Color(red: 0x17/255, green: 0x25/255, blue: 0x54/255), location: 1.0)
        ]),
        startPoint: .top,
        endPoint: .bottom
    )
}

/// Shown briefly while `AppContainerController.bootstrap()` is running. Prevents
/// the lock screen from racing against bootstrap to start (and being cancelled
/// by) the Face ID prompt. Visual matches the BlueLava family splash style.
private struct SplashView: View {
    var body: some View {
        ZStack {
            BlueLavaSplash.gradient.ignoresSafeArea()
            VStack(spacing: 4) {
                Text("BlueLava")
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("NetWorth")
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
    }
}

private struct LockedView: View {
    @Environment(AppContainerController.self) private var container

    var body: some View {
        ZStack {
            BlueLavaSplash.gradient.ignoresSafeArea()
            VStack(spacing: 4) {
                Text("BlueLava")
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("NetWorth")
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        // Tap anywhere on the locked screen to retry biometrics if the
        // initial prompt was dismissed.
        .contentShape(Rectangle())
        .onTapGesture {
            Task { await container.unlockWithBiometrics() }
        }
        .task { await container.unlockWithBiometrics() }
    }
}
