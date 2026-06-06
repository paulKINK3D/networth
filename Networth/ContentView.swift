import SwiftUI

struct ContentView: View {
    @Environment(AppContainerController.self) private var container
    @State private var selection: Int = 0
    @State private var alertPayload: PersistenceFailure?

    var body: some View {
        Group {
            if container.unlocked {
                tabs
            } else {
                LockedView()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectTab)) { note in
            if let tab = note.object as? Int { selection = tab }
        }
        .onChange(of: container.lastPersistenceError) { _, new in
            alertPayload = new
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
            SettingsView()
                .tabItem { Label("Settings", systemImage: NwIcon.settings.rawValue) }
                .tag(3)
        }
        .tint(NwAppColors.primary)
    }
}

private struct LockedView: View {
    @Environment(AppContainerController.self) private var container

    var body: some View {
        VStack(spacing: NwSpacing.xl) {
            Spacer()
            NwIcon.lock.image
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(NwAppColors.primary)
            Text("BlueLava Networth")
                .font(NwTypography.title)
            Text("Unlock with \(container.biometricGate.displayName) to continue.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, NwSpacing.xl)
            Button("Unlock") {
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
