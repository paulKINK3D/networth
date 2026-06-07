import Foundation
import Money

/// Where a persisted `DurableNetWorthSnapshot` row came from.
///
/// `.live` rows are written by `SnapshotScheduler.recordIfNeeded` during normal
/// app use and include manual assets. `.backfill` rows are written by the
/// one-time 24-month reconstruction and only include YNAB account balances
/// (manual-asset history doesn't extend that far back). When both kinds collide
/// on the same day, the dedupe pass prefers `.live` because it carries more
/// information.
public enum SnapshotSource: String, Sendable, Hashable, Codable, CaseIterable {
    case live
    case backfill
}

public struct NetWorthSnapshot: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    /// Day-resolution date (use the start of the local day).
    public let date: Date
    public let assets: Money
    public let liabilities: Money

    public var netWorth: Money { assets - liabilities }

    public init(id: UUID = UUID(), date: Date, assets: Money, liabilities: Money) {
        self.id = id
        self.date = date
        self.assets = assets
        self.liabilities = liabilities
    }
}

public struct NetWorthBreakdown: Sendable, Hashable, Codable {
    public let cash: Money
    public let investments: Money
    public let otherAssets: Money
    public let manualAssets: Money
    public let creditCardDebt: Money
    public let loans: Money
    public let otherLiabilities: Money

    public init(
        cash: Money = .zero,
        investments: Money = .zero,
        otherAssets: Money = .zero,
        manualAssets: Money = .zero,
        creditCardDebt: Money = .zero,
        loans: Money = .zero,
        otherLiabilities: Money = .zero
    ) {
        self.cash = cash
        self.investments = investments
        self.otherAssets = otherAssets
        self.manualAssets = manualAssets
        self.creditCardDebt = creditCardDebt
        self.loans = loans
        self.otherLiabilities = otherLiabilities
    }

    public var totalAssets: Money { cash + investments + otherAssets + manualAssets }
    public var totalLiabilities: Money { creditCardDebt + loans + otherLiabilities }
    public var netWorth: Money { totalAssets - totalLiabilities }
}
