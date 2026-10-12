import SwiftUI
import OSLog

/// Visual states for a choice chip. `selected` is the committed choice,
/// `suggested` outlines a best guess that still needs an explicit tap, and
/// `search` marks the chip that opens a full picker instead of choosing.
public enum NwChipStyle {
    case normal
    case selected
    case suggested
    case search
}

/// The styled chip content on its own, for wrapping in a Button or
/// NavigationLink while keeping every chip visually identical.
public struct NwChipLabel: View {
    private let title: String
    private let style: NwChipStyle

    public init(_ title: String, style: NwChipStyle = .normal) {
        self.title = title
        self.style = style
    }

    public var body: some View {
        HStack(spacing: NwSpacing.xs) {
            Text(title)
                .lineLimit(1)
            if style == .search {
                Image(systemName: "magnifyingglass")
                    .font(NwTypography.footnote)
            }
        }
        .font(
            style == .normal ? NwTypography.callout : NwTypography.bodyEmphasis
        )
        .foregroundStyle(foreground)
        .padding(.vertical, NwSpacing.sm + 2)
        .padding(.horizontal, NwSpacing.lg)
        .background(background, in: Capsule())
        .overlay(
            Capsule().strokeBorder(
                style == .suggested ? NwAppColors.primary : Color.clear,
                lineWidth: NwStrokeWidth.medium
            )
        )
        .contentShape(Capsule())
    }

    private var foreground: Color {
        switch style {
        case .normal: NwAppColors.textPrimary
        case .selected: NwAppColors.textOnPrimary
        case .suggested, .search: NwAppColors.primary
        }
    }

    private var background: Color {
        switch style {
        case .selected: NwAppColors.primary
        case .normal, .suggested, .search: NwAppColors.primary.opacity(0.10)
        }
    }
}

/// Shared transaction-review choice with a consistent, understated affordance.
public struct NwCompactChoiceLabel: View {
    private let title: String

    public init(_ title: String) { self.title = title }

    public var body: some View {
        HStack(spacing: NwSpacing.sm) {
            Text(title)
                .font(NwTypography.body.weight(.medium))
                .foregroundStyle(NwAppColors.textPrimary)
            Image(systemName: "chevron.down")
                .font(NwTypography.caption)
                .foregroundStyle(NwAppColors.textSecondary)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

public struct NwChoiceChip: View {
    private let title: String
    private let style: NwChipStyle
    private let action: () -> Void

    public init(
        _ title: String,
        style: NwChipStyle = .normal,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.style = style
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            NwChipLabel(title, style: style)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(style == .selected ? .isSelected : [])
    }
}

/// Left-aligned wrapping layout for chip rows: chips keep their ideal size
/// and flow onto new lines within the proposed width.
public struct NwChipFlow: Layout {
    private let spacing: CGFloat

    public init(spacing: CGFloat = NwSpacing.sm) {
        self.spacing = spacing
    }

    public func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let timing = NwPerformanceTrace.begin("Chip flow measurement")
        defer { NwPerformanceTrace.end(timing) }
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(
            width: maxWidth == .infinity ? widest : maxWidth,
            height: y + rowHeight
        )
    }

    public func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let timing = NwPerformanceTrace.begin("Chip flow placement")
        defer { NwPerformanceTrace.end(timing) }
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                proposal: ProposedViewSize(size)
            )
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Static operation names and durations only: no financial data or search text.
/// Instruments sees every interval; Console receives operations over 16 ms.
enum NwPerformanceTrace {
    private static let logger = Logger(subsystem: "com.bluelava.me.networth", category: "InteractionTiming")
    private static let signposter = OSSignposter(logger: logger)

    struct Span {
        let name: StaticString
        let started: TimeInterval
        let interval: OSSignpostIntervalState
    }

    static func begin(_ name: StaticString) -> Span {
        Span(name: name, started: ProcessInfo.processInfo.systemUptime,
             interval: signposter.beginInterval(name, id: signposter.makeSignpostID()))
    }

    static func end(_ span: Span, canceled: Bool = false) {
        let milliseconds = (ProcessInfo.processInfo.systemUptime - span.started) * 1_000
        signposter.endInterval(span.name, span.interval)
        if milliseconds >= 16 {
            logger.notice("\(String(describing: span.name), privacy: .public): \(milliseconds, privacy: .public) ms; canceled=\(canceled, privacy: .public)")
        }
    }
}

/// The same two-row classification surface for whole transactions and splits.
struct NwReviewCard<Top: View, Details: View>: View {
    var showsDetails: Bool = true
    @ViewBuilder var top: () -> Top
    @ViewBuilder var details: () -> Details

    var body: some View {
        NwCard(style: .primary) {
            VStack(alignment: .leading, spacing: NwSpacing.sm) {
                top()
                if showsDetails {
                    Divider()
                    details()
                }
            }
        }
    }
}

struct NwReviewChoices<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: NwSpacing.lg) {
                leading().fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
                trailing().fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: NwSpacing.xs) {
                leading()
                trailing()
            }
        }
    }
}
