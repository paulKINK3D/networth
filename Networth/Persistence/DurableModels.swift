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
    /// Optional grouping label. Two assets sharing the same non-empty
    /// `groupName` render together with a summed header — e.g. an institution
    /// label like "Vanguard" containing per-account rows "IRA" and "401k".
    /// `nil` or empty = ungrouped.
    public var groupName: String? = nil

    @Relationship(deleteRule: .cascade, inverse: \DurableManualAssetValue.asset)
    public var values: [DurableManualAssetValue]? = []

    public init(
        id: UUID = UUID(),
        name: String = "",
        kind: ManualAssetKind = .other,
        lastUpdatedAt: Date = .now,
        notes: String? = nil,
        groupName: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kindRaw = kind.rawValue
        self.lastUpdatedAt = lastUpdatedAt
        self.notes = notes
        self.groupName = groupName
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
    /// Raw `SnapshotSource.rawValue`. Defaults to `"live"` so legacy rows that
    /// predate this field are treated as live snapshots (which is what they
    /// were — only `recordIfNeeded` wrote snapshots before backfill existed).
    public var sourceRaw: String = SnapshotSource.live.rawValue
    /// First-write time on this device. Used as a dedupe tiebreaker among same-
    /// source rows so the freshest write survives.
    public var createdAt: Date = Date.now

    public init(
        id: UUID = UUID(),
        date: Date = .now,
        assetsMilliunits: Int64 = 0,
        liabilitiesMilliunits: Int64 = 0,
        source: SnapshotSource = .live,
        createdAt: Date = .now
    ) {
        self.id = id
        self.date = date
        self.assetsMilliunits = assetsMilliunits
        self.liabilitiesMilliunits = liabilitiesMilliunits
        self.sourceRaw = source.rawValue
        self.createdAt = createdAt
    }

    public var assets: Money { Money(milliunits: assetsMilliunits) }
    public var liabilities: Money { Money(milliunits: liabilitiesMilliunits) }
    public var netWorth: Money { assets - liabilities }
    public var source: SnapshotSource { SnapshotSource(rawValue: sourceRaw) ?? .live }
}

@Model
public final class DurableCardSettings {
    public var accountId: String = ""
    public var statementCycleDay: Int = 1
    public var minimumPaymentPercentNumerator: Int = 2
    public var minimumPaymentPercentDenominator: Int = 100
    public var minimumPaymentFloorMilliunits: Int64 = 25_000
    /// Day of the month autopay debits checking for this card. `0` means
    /// "not set yet" — UI skips cards until both close + due days are set.
    /// Days 29-31 fall back to the last day of short months.
    public var paymentDueDay: Int = 0
    /// Cash account that funds this card's full-statement autopay.
    public var paymentAccountId: String? = nil

    public init(
        accountId: String,
        statementCycleDay: Int = 1,
        minimumPaymentPercentNumerator: Int = 2,
        minimumPaymentPercentDenominator: Int = 100,
        minimumPaymentFloorMilliunits: Int64 = 25_000,
        paymentDueDay: Int = 0,
        paymentAccountId: String? = nil
    ) {
        self.accountId = accountId
        self.statementCycleDay = max(1, min(31, statementCycleDay))
        self.minimumPaymentPercentNumerator = minimumPaymentPercentNumerator
        self.minimumPaymentPercentDenominator = minimumPaymentPercentDenominator
        self.minimumPaymentFloorMilliunits = minimumPaymentFloorMilliunits
        self.paymentDueDay = max(0, min(31, paymentDueDay))
        self.paymentAccountId = paymentAccountId
    }

    public var minimumPaymentPercent: Decimal {
        Decimal(minimumPaymentPercentNumerator) / Decimal(minimumPaymentPercentDenominator)
    }

    public var minimumPaymentFloor: Money { Money(milliunits: minimumPaymentFloorMilliunits) }

    public func toCore() -> CardStatementSettings {
        CardStatementSettings(
            accountId: accountId,
            statementCycleDay: statementCycleDay,
            paymentDueDay: paymentDueDay,
            paymentAccountId: paymentAccountId,
            minimumPaymentPercent: minimumPaymentPercent,
            minimumPaymentFloor: minimumPaymentFloor
        )
    }
}

@Model
public final class DurableUserSettings {
    public var id: String = "singleton"
    /// Defaults to true: new installs are locked behind biometrics on every
    /// launch. Users can opt out in Settings → Authentication.
    public var faceIDEnabled: Bool = true
    public var selectedBudgetId: String? = nil
    public var lastSyncedAt: Date? = nil
    public var dipThresholdMilliunits: Int64 = 500_000  // $500
    public var historyHorizonMonths: Int = 60
    public var projectionHorizonDays: Int = 90
    public var hasSeenTutorial: Bool = false
    public var spendingLookbackDays: Int = 365
    /// Bumped when a one-time migration changes existing settings defaults.
    /// Version 2 = enable Face ID when biometric is available.
    /// Version 3 = normalize expected-spending lookback to 365 days.
    public var settingsSchemaVersion: Int = 0
    /// `0` = backfill not yet run on this iCloud account. Bumped to the
    /// current version (`SyncCoordinator.currentHistoryBackfillVersion`) after
    /// the 5-year historical reconstruction successfully writes snapshots.
    /// Lives here (CloudKit-synced) instead of in the disposable local cache
    /// so a device reinstall or restore doesn't accidentally re-run backfill.
    public var historyBackfillVersion: Int = 0
    /// Wall-clock time the last successful backfill completed. Compared to
    /// `DurableManualAsset.lastUpdatedAt` on bootstrap: if any manual asset
    /// is newer than this, the snapshots that came back via CloudKit are
    /// stale (a different device added/changed an asset) and the backfill
    /// re-runs to pick up the new contributions.
    public var lastBackfillRunAt: Date? = nil
    /// Minutes the app considers a recent unlock still trusted. On cold
    /// launch, if `Date.now - lastBackgroundedAt < biometricGraceMinutes`,
    /// Face ID is skipped. Defaults to 30 minutes so the user doesn't get
    /// re-prompted every time iOS evicts the app from memory shortly after
    /// backgrounding.
    public var biometricGraceMinutes: Int = 30
    /// User-chosen floor for the trend chart. When set, the chart, the
    /// backfill window, and the trend diagnostic all clamp to dates on or
    /// after this. Use case: when the historical reconstruction produces
    /// values the user knows are wrong (e.g. because real investment
    /// balances aren't entered in YNAB and outflows look like expenses),
    /// they reset the chart to "start fresh" from a chosen date.
    /// `nil` = no floor (default behavior: 60 months back).
    public var chartStartDate: Date? = nil

    public init(id: String = "singleton") { self.id = id }
}

/// One row per closed YNAB account the user wants to include in the trend
/// chart's historical reconstruction. Default is to leave closed accounts
/// out (matches the original behavior); the user opts a closed account in
/// when its YNAB history is genuinely relevant to historical net worth
/// (e.g. brokerage staging accounts the user funded then drained).
@Model
public final class DurableIncludedClosedAccount {
    public var accountId: String = ""
    public var addedAt: Date = Date.now

    public init(accountId: String = "", addedAt: Date = .now) {
        self.accountId = accountId
        self.addedAt = addedAt
    }
}

/// One row per YNAB category the user has opted out of the variable-spend
/// projection. Stored in the CloudKit-backed store so the exclusion list
/// follows the user across devices.
@Model
public final class DurableExcludedSpendCategory {
    public var categoryId: String = ""
    public var categoryName: String = ""
    public var groupName: String = ""
    public var createdAt: Date = Date.now

    public init(categoryId: String = "", categoryName: String = "", groupName: String = "") {
        self.categoryId = categoryId
        self.categoryName = categoryName
        self.groupName = groupName
    }
}

/// One user-excluded YNAB transaction or split leg. This is additive durable
/// CloudKit data; transaction IDs remain stable across YNAB delta syncs.
@Model
public final class DurableExcludedSpendTransaction {
    public var id: UUID = UUID()
    public var transactionId: String = ""
    public var payeeName: String = ""
    public var transactionDate: Date = Date.now
    public var amountMilliunits: Int64 = 0
    public var createdAt: Date = Date.now

    public init(
        id: UUID = UUID(),
        transactionId: String = "",
        payeeName: String = "",
        transactionDate: Date = .now,
        amountMilliunits: Int64 = 0,
        createdAt: Date = .now
    ) {
        self.id = id
        self.transactionId = transactionId
        self.payeeName = payeeName
        self.transactionDate = transactionDate
        self.amountMilliunits = amountMilliunits
        self.createdAt = createdAt
    }
}

/// A durable override to the projection cash-pool default. Open on-budget
/// cash accounts default on; off-budget cash accounts default off.
@Model
public final class DurableProjectionCashAccountOverride {
    public var id: UUID = UUID()
    public var accountId: String = ""
    public var included: Bool = false

    public init(id: UUID = UUID(), accountId: String = "", included: Bool = false) {
        self.id = id
        self.accountId = accountId
        self.included = included
    }
}

/// The user's durable decision about whether a Plaid account is additive or
/// already represented elsewhere. All fields have defaults for additive
/// CloudKit schema compatibility.
@Model
public final class DurablePlaidAccountTreatment {
    public var id: UUID = UUID()
    public var plaidAccountId: String = ""
    public var treatmentRaw: String = PlaidAccountTreatment.pendingReview.rawValue
    public var duplicateSourceId: String? = nil
    public var updatedAt: Date = Date.now

    public init(
        id: UUID = UUID(),
        plaidAccountId: String = "",
        treatment: PlaidAccountTreatment = .pendingReview,
        duplicateSourceId: String? = nil,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.plaidAccountId = plaidAccountId
        self.treatmentRaw = treatment.rawValue
        self.duplicateSourceId = duplicateSourceId
        self.updatedAt = updatedAt
    }

    public var treatment: PlaidAccountTreatment {
        get { PlaidAccountTreatment(rawValue: treatmentRaw) ?? .pendingReview }
        set { treatmentRaw = newValue.rawValue }
    }
}

/// One durable, per-account Plaid balance observation for a calendar day.
/// This is additive private-CloudKit data and is intentionally separate from
/// the disposable Plaid cache. An inactive row ends the account's contribution
/// without deleting its earlier history. Every stored property has a default
/// for CloudKit schema compatibility.
@Model
public final class DurablePlaidBalanceSnapshot {
    public var id: UUID = UUID()
    public var plaidAccountId: String = ""
    public var matchedManualAssetId: UUID? = nil
    public var date: Date = Date.now
    public var balanceMilliunits: Int64 = 0
    public var active: Bool = true
    public var recordedAt: Date = Date.now

    public init(
        id: UUID = UUID(),
        plaidAccountId: String = "",
        matchedManualAssetId: UUID? = nil,
        date: Date = .now,
        balanceMilliunits: Int64 = 0,
        active: Bool = true,
        recordedAt: Date = .now
    ) {
        self.id = id
        self.plaidAccountId = plaidAccountId
        self.matchedManualAssetId = matchedManualAssetId
        self.date = date
        self.balanceMilliunits = balanceMilliunits
        self.active = active
        self.recordedAt = recordedAt
    }

    public var balance: Money { Money(milliunits: balanceMilliunits) }

    public func toHistorySnapshot() -> InvestmentHistoryBuilder.PlaidBalanceSnapshot {
        InvestmentHistoryBuilder.PlaidBalanceSnapshot(
            accountID: plaidAccountId,
            matchedManualAssetID: matchedManualAssetId,
            date: date,
            balance: balance,
            isActive: active,
            recordedAt: recordedAt
        )
    }
}

/// Resolves which current investment balances come from Plaid without
/// double-counting a matched manual asset. Manual model values remain intact;
/// a valid match overlays them only while the Plaid cache has a supported
/// current balance. Multiple Plaid accounts may replace one aggregate manual
/// asset, in which case their balances are summed.
struct PlaidContributionResolver {
    let standalonePlaidAccounts: [CachedPlaidAccount]
    private let replacementAccountsByManualAssetID: [UUID: [CachedPlaidAccount]]
    private let matchedManualAssetIDByPlaidAccountID: [String: UUID]

    init(
        plaidAccounts: [CachedPlaidAccount],
        treatments: [DurablePlaidAccountTreatment],
        manualAssets: [DurableManualAsset]
    ) {
        var treatmentByAccountID: [String: DurablePlaidAccountTreatment] = [:]
        for treatment in treatments {
            treatmentByAccountID[treatment.plaidAccountId] = treatment
        }

        standalonePlaidAccounts = plaidAccounts.filter { account in
            treatmentByAccountID[account.id]?.treatment == .included
                && Self.canContribute(account)
        }

        // Reconciliation is about identity, not Plaid's account taxonomy.
        // Some institutions expose cash-like accounts through Investments, so
        // the matched manual asset remains authoritative for classification.
        let eligibleManualIDs = Set(manualAssets.compactMap { asset in
            asset.deleted ? nil : asset.id
        })

        var candidates: [UUID: [CachedPlaidAccount]] = [:]
        for account in plaidAccounts {
            guard let treatment = treatmentByAccountID[account.id],
                  treatment.treatment == .duplicateManualAsset,
                  let sourceID = treatment.duplicateSourceId,
                  let manualAssetID = UUID(uuidString: sourceID),
                  eligibleManualIDs.contains(manualAssetID) else {
                continue
            }
            candidates[manualAssetID, default: []].append(account)
        }

        replacementAccountsByManualAssetID = candidates.filter { _, accounts in
            !accounts.isEmpty && accounts.allSatisfy(Self.canContribute)
        }
        matchedManualAssetIDByPlaidAccountID = Dictionary(
            uniqueKeysWithValues: replacementAccountsByManualAssetID.flatMap { manualID, accounts in
                accounts.map { ($0.id, manualID) }
            }
        )
    }

    var contributingPlaidAccounts: [CachedPlaidAccount] {
        standalonePlaidAccounts
            + replacementAccountsByManualAssetID.values.flatMap { $0 }
    }

    var contributingPlaidAccountIDs: Set<String> {
        Set(contributingPlaidAccounts.map(\.id))
    }

    func replacementAccounts(for asset: DurableManualAsset) -> [CachedPlaidAccount] {
        replacementAccountsByManualAssetID[asset.id] ?? []
    }

    func matchedManualAssetID(for account: CachedPlaidAccount) -> UUID? {
        matchedManualAssetIDByPlaidAccountID[account.id]
    }

    func replacementBalance(for asset: DurableManualAsset) -> Money? {
        let accounts = replacementAccounts(for: asset)
        guard !accounts.isEmpty else { return nil }
        return accounts.compactMap(\.currentBalance).sum()
    }

    func effectiveValue(for asset: DurableManualAsset) -> Money {
        replacementBalance(for: asset) ?? asset.currentValue
    }

    func isReplacing(_ asset: DurableManualAsset) -> Bool {
        replacementAccountsByManualAssetID[asset.id] != nil
    }

    private static func canContribute(_ account: CachedPlaidAccount) -> Bool {
        account.unofficialCurrencyCode == nil
            && account.isoCurrencyCode?.uppercased() == "USD"
            && account.currentBalance != nil
    }
}
