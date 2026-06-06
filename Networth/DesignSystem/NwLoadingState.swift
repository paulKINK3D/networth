import SwiftUI

public struct NwLoadingState: View {
    public let message: String

    public init(_ message: String = "Loading…") { self.message = message }

    public var body: some View {
        VStack(spacing: NwSpacing.md) {
            ProgressView().controlSize(.large)
            Text(message)
                .font(NwTypography.callout)
                .foregroundStyle(NwAppColors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
