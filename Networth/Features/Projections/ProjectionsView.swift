import SwiftUI

/// Projections tab — emptied out for a clean rebuild.
struct ProjectionsView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: NwSpacing.lg) {
                Spacer()
                NwEmptyState(
                    title: "Projections coming back soon",
                    message: "This tab is being rebuilt from scratch.",
                    icon: .projections
                )
                Spacer()
            }
            .padding(.horizontal, NwSpacing.screenPadding)
            .background(NwAppColors.background.ignoresSafeArea())
            .navigationTitle("Projections")
        }
    }
}
