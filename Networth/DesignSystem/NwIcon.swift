import SwiftUI

/// SF Symbols catalog. Use these names instead of raw strings so renames stay in one place.
public enum NwIcon: String, Sendable {
    // Navigation
    case netWorth     = "chart.line.uptrend.xyaxis"
    case budget       = "dollarsign.circle"
    case projections  = "calendar.badge.clock"
    case goals        = "target"
    case accounts     = "building.columns"
    case categories   = "tag"
    case settings     = "gearshape"

    // Account types
    case checking     = "banknote"
    case savings      = "dollarsign.bank.building"
    case creditCard   = "creditcard"
    case mortgage     = "house"
    case autoLoan     = "car"
    case studentLoan  = "graduationcap"
    case investment   = "chart.pie"
    case cash         = "dollarsign"
    case realEstate   = "house.lodge"
    case vehicle      = "car.side"
    case brokerage    = "chart.bar.xaxis"
    case retirement   = "leaf.fill"
    case crypto       = "bitcoinsign.circle"
    case collectible  = "diamond"
    case otherAsset   = "shippingbox"
    case otherLiability = "exclamationmark.triangle"

    // Status
    case success      = "checkmark.circle.fill"
    case attention    = "exclamationmark.circle.fill"
    case warning      = "exclamationmark.triangle.fill"
    case error        = "xmark.octagon.fill"
    case info         = "info.circle.fill"

    // Common controls
    case close        = "xmark.circle.fill"
    case confirm      = "checkmark.circle"
    case add          = "plus"
    case edit         = "pencil"
    case delete       = "trash"
    case sync         = "arrow.clockwise"
    case lock         = "lock.fill"
    case faceID       = "faceid"
    case keychain     = "key.fill"
    case cloud        = "icloud"
    case notification = "bell.fill"
    case photo        = "photo"
    case connected    = "link.circle.fill"
    case history      = "clock.arrow.circlepath"
    case chevron      = "chevron.right"
    case arrowUp      = "arrow.up.right"
    case arrowDown    = "arrow.down.right"
    case cashIn       = "arrow.down.left.circle.fill"
    case cashOut      = "arrow.up.right.circle.fill"
    case awaiting     = "clock.badge.exclamationmark"
    case empty        = "tray"

    public var image: Image { Image(systemName: rawValue) }
}

/// Compact status mark for values maintained by a live external connection.
public struct NwConnectionIndicator: View {
    public init() {}

    public var body: some View {
        NwIcon.connected.image
            .font(NwTypography.footnoteEm)
            .foregroundStyle(NwAppColors.positive)
            .accessibilityLabel("Connected")
    }
}

extension NwIcon {
    public static func forAccountKind(_ kind: String) -> NwIcon {
        switch kind {
        case "checking":   return .checking
        case "savings":    return .savings
        case "cash":       return .cash
        case "creditCard": return .creditCard
        case "lineOfCredit": return .creditCard
        case "mortgage":   return .mortgage
        case "autoLoan":   return .autoLoan
        case "studentLoan":return .studentLoan
        case "personalLoan", "medicalDebt", "otherDebt": return .otherLiability
        case "investment": return .investment
        case "otherLiability": return .otherLiability
        case "otherAsset": return .otherAsset
        default:           return .otherAsset
        }
    }
}
