import Foundation
import SwiftData
import NetworthCore

/// Models stored in the CloudKit-backed private DB. Holds irreplaceable user data:
/// manual assets + their value history, daily net-worth snapshots, projection settings,
/// and user preferences. **Never** put cached YNAB data in this container.
///
/// CloudKit requires every property to be optional, defaulted, or a relationship.
/// We default everything to safe empty values.

@Model
public final class DurableManualAsset {
    public var id: UUID = UUID()
    public var name: String = ""
    public var kindRaw: String = ManualAssetKind.other.rawValue
    public var lastUpdatedAt: Date = Date.now
    public var notes: String? = nil
    public var deleted: Bool = false

    @Relationship(deleteRule: .cascade, inverse: \DurableManualAssetValue.asset)
    public var values: [DurableManualAssetValue]? = []

    public init(
        id: UUID = UUID(),
        name: String = "",
        kind: ManualAssetKind = .other,
        lastUpdatedAt: Date = .now,
        notes: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kindRaw = kind.rawValue
        self.lastUpdatedAt = lastUpdatedAt
        self.notes = notes
    }

    public var kind: ManualAssetKind {
        ManualAssetKind(rawValue: kindRaw) ?? .other
    }

    public var currentValueMilliunits: Int64 {
        sortedValues.last?.amountMilliunits ?? 0
    }

    public var currentValue: Money { Money(milliunits: currentValueMilliunits) }

    public var sortedValues: [DurableManualAssetValue] {
        (values ?? []).sorted { $0.recordedAt < $1.recordedAt }
    }

    public func toSnapshot() -> ManualAssetSnapshot {
        let history = sortedValues.map {
            ManualAssetValueEntry(id: $0.id, recordedAt: $0.recordedAt,
                                  value: Money(milliunits: $0.amountMilliunits), note: $0.note)
        }
        return ManualAssetSnapshot(
            id: id, name: name, kind: kind,
            currentValue: currentValue,
            lastUpdatedAt: lastUpdatedAt,
            history: history
        )
    }
}

@Model
public final class DurableManualAssetValue {
    public var id: UUID = UUID()
    public var recordedAt: Date = Date.now
    public var amountMilliunits: Int64 = 0
    public var note: String? = nil
    public var asset: DurableManualAsset?

    public init(
        id: UUID = UUID(),
        recordedAt: Date = .now,
        amountMilliunits: Int64 = 0,
        note: String? = nil,
        asset: DurableManualAsset? = nil
    ) {
        self.id = id
        self.recordedAt = recordedAt
        self.amountMilliunits = amountMilliunits
        self.note = note
        self.asset = asset
    }
}

@Model
public final class DurableNetWorthSnapshot {
    public var id: UUID = UUID()
    public var date: Date = Date.now
    public var assetsMilliunits: Int64 = 0
    public var liabilitiesMilliunits: Int64 = 0

    public init(id: UUID = UUID(), date: Date = .now, assetsMilliunits: Int64 = 0, liabilitiesMilliunits: Int64 = 0) {
        self.id = id
        self.date = date
        self.assetsMilliunits = assetsMilliunits
        self.liabilitiesMilliunits = liabilitiesMilliunits
    }

    public var assets: Money { Money(milliunits: assetsMilliunits) }
    public var liabilities: Money { Money(milliunits: liabilitiesMilliunits) }
    public var netWorth: Money { assets - liabilities }
}

@Model
public final class DurableCardSettings {
    public var accountId: String = ""
    public var statementCycleDay: Int = 1
    public var minimumPaymentPercentNumerator: Int = 2
    public var minimumPaymentPercentDenominator: Int = 100
    public var minimumPaymentFloorMilliunits: Int64 = 25_000

    public init(
        accountId: String,
        statementCycleDay: Int = 1,
        minimumPaymentPercentNumerator: Int = 2,
        minimumPaymentPercentDenominator: Int = 100,
        minimumPaymentFloorMilliunits: Int64 = 25_000
    ) {
        self.accountId = accountId
        self.statementCycleDay = max(1, min(28, statementCycleDay))
        self.minimumPaymentPercentNumerator = minimumPaymentPercentNumerator
        self.minimumPaymentPercentDenominator = minimumPaymentPercentDenominator
        self.minimumPaymentFloorMilliunits = minimumPaymentFloorMilliunits
    }

    public var minimumPaymentPercent: Decimal {
        Decimal(minimumPaymentPercentNumerator) / Decimal(minimumPaymentPercentDenominator)
    }

    public var minimumPaymentFloor: Money { Money(milliunits: minimumPaymentFloorMilliunits) }

    public func toCore() -> CardStatementSettings {
        CardStatementSettings(
            accountId: accountId,
            statementCycleDay: statementCycleDay,
            minimumPaymentPercent: minimumPaymentPercent,
            minimumPaymentFloor: minimumPaymentFloor
        )
    }
}

@Model
public final class DurableUserSettings {
    public var id: String = "singleton"
    public var faceIDEnabled: Bool = false
    public var selectedBudgetId: String? = nil
    public var lastSyncedAt: Date? = nil
    public var dipThresholdMilliunits: Int64 = 500_000  // $500
    public var historyHorizonMonths: Int = 24
    public var projectionHorizonDays: Int = 90

    public init(id: String = "singleton") { self.id = id }
}
