import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(AppContainerController.self) private var container
    @Query private var userSettings: [DurableUserSettings]
    @State private var selection: Int = 0
    @State private var alertPayload: PersistenceFailure?
    @State private var showingTutorial = false
    @State private var showingSettings = false

    var body: some View {
        Group {
            if !container.bootstrapped {
                SplashView()
            } else if container.unlocked {
                tabs
            } else {
                LockedView()
            }
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

/// Shown briefly while `AppContainerController.bootstrap()` is running. Prevents
/// the lock screen from racing against bootstrap to start (and being cancelled
/// by) the Face ID prompt.
private struct SplashView: View {
    var body: some View {
        VStack(spacing: NwSpacing.lg) {
            ZStack {
                Circle()
                    .fill(NwAppColors.primary.opacity(0.12))
                    .frame(width: 120, height: 120)
                NwIcon.netWorth.image
                    .font(.system(size: 52, weight: .light))
                    .foregroundStyle(NwAppColors.primary)
            }
            Text("BlueLava\nNetworth")
                .font(NwTypography.title)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NwAppColors.background.ignoresSafeArea())
    }
}

private struct LockedView: View {
    @Environment(AppContainerController.self) private var container

    var body: some View {
        VStack(spacing: NwSpacing.xl) {
            Spacer()
            ZStack {
                Circle()
                    .fill(NwAppColors.primary.opacity(0.12))
                    .frame(width: 120, height: 120)
                NwIcon.lock.image
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(NwAppColors.primary)
            }
            VStack(spacing: NwSpacing.sm) {
                Text("BlueLava\nNetworth")
                    .font(NwTypography.title)
                    .multilineTextAlignment(.center)
                Text("Your private financial dashboard")
                    .font(NwTypography.callout)
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: NwSpacing.md) {
                Text("Authenticate with \(container.biometricGate.displayName) to view your net worth, projections, and accounts.")
                    .font(NwTypography.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text("Your data is stored only on your devices and in your private iCloud — never shared.")
                    .font(NwTypography.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, NwSpacing.xl)
            Button("Unlock with \(container.biometricGate.displayName)") {
                Task { await container.unlockWithBiometrics() }
            }
            .buttonStyle(NwPrimaryButtonStyle())
            .padding(.horizontal, NwSpacing.xl)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NwAppColors.background.ignoresSafeArea())
        .task { await container.unlockWithBiometrics() }
    }
}
