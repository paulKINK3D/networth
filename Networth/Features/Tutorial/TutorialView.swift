import SwiftUI
import SwiftData

/// Paginated walkthrough. Presented as a sheet from `ContentView` on first unlock
/// and re-triggerable from Settings. Marks `DurableUserSettings.hasSeenTutorial`
/// when the user reaches the final step or taps Skip.
struct TutorialView: View {
    @Environment(AppContainerController.self) private var container
    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex: Int = 0

    private let steps = TutorialContent.steps

    var body: some View {
        VStack(spacing: 0) {
            header

            TabView(selection: $currentIndex) {
                ForEach(steps.indices, id: \.self) { index in
                    TutorialPageView(step: steps[index])
                        .tag(index)
                        .padding(.horizontal, NwSpacing.screenPadding)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(.easeInOut(duration: 0.25), value: currentIndex)

            pageIndicator
            footer
        }
        .background(NwAppColors.background.ignoresSafeArea())
        .interactiveDismissDisabled(true)
    }

    private var header: some View {
        HStack {
            Spacer().frame(width: 60)
            Spacer()
            Text("Quick Tour")
                .font(NwTypography.headline)
            Spacer()
            Button("Skip") { finish() }
                .font(NwTypography.footnoteEm)
                .foregroundStyle(NwAppColors.textSecondary)
                .frame(width: 60, alignment: .trailing)
        }
        .padding(.horizontal, NwSpacing.screenPadding)
        .padding(.vertical, NwSpacing.md)
        .background(NwAppColors.background)
    }

    private var pageIndicator: some View {
        HStack(spacing: NwSpacing.xs) {
            ForEach(steps.indices, id: \.self) { i in
                Capsule()
                    .fill(i == currentIndex ? NwAppColors.primary : NwAppColors.strokeSubtle)
                    .frame(width: i == currentIndex ? 22 : 6, height: 6)
                    .animation(.easeInOut(duration: 0.2), value: currentIndex)
            }
        }
        .padding(.vertical, NwSpacing.md)
    }

    private var footer: some View {
        HStack(spacing: NwSpacing.md) {
            if currentIndex > 0 {
                Button("Back") {
                    withAnimation { currentIndex -= 1 }
                }
                .buttonStyle(NwSecondaryButtonStyle())
            }
            Button(isLastStep ? "Get Started" : "Next") {
                if isLastStep {
                    finish()
                } else {
                    withAnimation { currentIndex += 1 }
                }
            }
            .buttonStyle(NwPrimaryButtonStyle())
        }
        .padding(.horizontal, NwSpacing.screenPadding)
        .padding(.bottom, NwSpacing.lg)
        .padding(.top, NwSpacing.sm)
        .background(NwAppColors.background)
    }

    private var isLastStep: Bool { currentIndex == steps.count - 1 }

    private func finish() {
        let ctx = container.modelContainer.mainContext
        let descriptor = FetchDescriptor<DurableUserSettings>()
        let settings: DurableUserSettings
        if let existing = try? ctx.fetch(descriptor).first {
            settings = existing
        } else {
            settings = DurableUserSettings()
            ctx.insert(settings)
        }
        settings.hasSeenTutorial = true
        ctx.safeSave(source: "tutorial.finish")
        dismiss()
    }
}

private struct TutorialPageView: View {
    let step: TutorialStep

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NwSpacing.xl) {
                iconBlock

                VStack(alignment: .leading, spacing: NwSpacing.sm) {
                    Text(step.title)
                        .font(NwTypography.title)
                        .foregroundStyle(NwAppColors.textPrimary)

                    Text(step.lede)
                        .font(NwTypography.body)
                        .foregroundStyle(NwAppColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                NwCard(style: .primary) {
                    VStack(alignment: .leading, spacing: NwSpacing.md) {
                        ForEach(Array(step.bullets.enumerated()), id: \.offset) { _, bullet in
                            HStack(alignment: .top, spacing: NwSpacing.md) {
                                Circle()
                                    .fill(step.iconTint)
                                    .frame(width: 6, height: 6)
                                    .padding(.top, 8)
                                Text(bullet)
                                    .font(NwTypography.body)
                                    .foregroundStyle(NwAppColors.textPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }

                if let footnote = step.footnote {
                    HStack(alignment: .top, spacing: NwSpacing.sm) {
                        NwIcon.info.image
                            .foregroundStyle(NwAppColors.info)
                        Text(footnote)
                            .font(NwTypography.footnote)
                            .foregroundStyle(NwAppColors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, NwSpacing.md)
                }

                Spacer(minLength: NwSpacing.xl)
            }
            .padding(.top, NwSpacing.lg)
        }
    }

    private var iconBlock: some View {
        ZStack {
            Circle()
                .fill(step.iconTint.opacity(0.12))
                .frame(width: 88, height: 88)
            step.icon.image
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(step.iconTint)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}
