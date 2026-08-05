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
    /// Additive source-neutral replacement for `accountId`. Legacy installs
    /// continue reading the YNAB ID until account reconciliation fills this.
    public var canonicalAccountId: String? = nil
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
    public var canonicalPaymentAccountId: String? = nil

    public init(
        accountId: String,
        statementCycleDay: Int = 1,
        minimumPaymentPercentNumerator: Int = 2,
        minimumPaymentPercentDenominator: Int = 100,
        minimumPaymentFloorMilliunits: Int64 = 25_000,
        paymentDueDay: Int = 0,
        paymentAccountId: String? = nil,
        canonicalAccountId: String? = nil,
        canonicalPaymentAccountId: String? = nil
    ) {
        self.accountId = accountId
        self.statementCycleDay = max(1, min(31, statementCycleDay))
        self.minimumPaymentPercentNumerator = minimumPaymentPercentNumerator
        self.minimumPaymentPercentDenominator = minimumPaymentPercentDenominator
        self.minimumPaymentFloorMilliunits = minimumPaymentFloorMilliunits
        self.paymentDueDay = max(0, min(31, paymentDueDay))
        self.paymentAccountId = paymentAccountId
        self.canonicalAccountId = canonicalAccountId
        self.canonicalPaymentAccountId = canonicalPaymentAccountId
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
    /// One monthly cap shared by every category in the discretionary envelope.
    public var discretionaryMonthlyTargetMilliunits: Int64 = 0
    /// JSON-encoded stable canonical category IDs. Nil means the confirmed
    /// name/group defaults have not yet been materialized for this user.
    public var discretionaryCategoryIdsData: Data? = nil
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
    /// `"ynab"` during comparison and `"plaid"` after explicit cutover.
    public var primaryFinancialDataSourceRaw: String = FinancialDataSource.ynab.rawValue
    public var plaidTransactionsEnabled: Bool = false
    public var claudeFallbackEnabled: Bool = false
    public var claudeFallbackConsentAt: Date? = nil
    /// Opt-in read-only Claude.ai connector. These additive defaulted fields
    /// are CloudKit-safe: existing records hydrate with sync disabled and no
    /// migration or legacy-field cleanup is required.
    public var claudeDataSyncEnabled: Bool = false
    public var claudeDataSyncConsentAt: Date? = nil
    public var claudeDataLastSyncedAt: Date? = nil
    public var plaidPrimaryCutoverAt: Date? = nil
    /// Version of the YNAB-first transaction data model. Version 1 discards
    /// the former fingerprint/rule review state and rebuilds from canonical
    /// YNAB payees, categories, and transaction history.
    public var canonicalTransactionDataVersion: Int = 0
    /// Set when the user finishes the one-time Budget setup review (buckets,
    /// income pattern, fixed commitments, surplus target). Nil gates the
    /// Budget tab behind setup. Additive defaulted fields are CloudKit-safe.
    public var budgetSetupCompletedAt: Date? = nil
    /// The single user-defined True Surplus envelope. Defaults to $1,000.
    public var budgetSurplusTargetMilliunits: Int64 = 1_000_000
    /// `0` = the Plaid-first destructive clean start has not completed for
    /// this iCloud account. Set to `FreshStart.currentVersion` only after
    /// every row in both stores was deleted and this fresh default row was
    /// created. Rows carrying an older value that reappear via CloudKit are
    /// legacy and get purged at bootstrap.
    public var freshStartVersion: Int = 0
    /// First successful Plaid sync after the clean start. Gates the first
    /// new Net Worth snapshot: history starts on that date and is never
    /// reconstructed from YNAB.
    public var firstPlaidSyncCompletedAt: Date? = nil

    public init(id: String = "singleton") { self.id = id }

    public var primaryFinancialDataSource: FinancialDataSource {
        get { FinancialDataSource(rawValue: primaryFinancialDataSourceRaw) ?? .ynab }
        set { primaryFinancialDataSourceRaw = newValue.rawValue }
    }

    public var discretionaryCategoryIds: Set<String> {
        get {
            guard let discretionaryCategoryIdsData,
                  let values = try? JSONDecoder().decode(
                      [String].self,
                      from: discretionaryCategoryIdsData
                  ) else {
                return []
            }
            return Set(values)
        }
        set {
            discretionaryCategoryIdsData = try? JSONEncoder().encode(
                newValue.sorted()
            )
        }
    }
}

/// Networth's editable, durable contact/payee directory. YNAB is the seed
/// source, while future user-confirmed Plaid aliases expand the directory.
/// `sourceName` is retained as audit evidence; edits change `name` only.
@Model
public final class DurableCanonicalPayee {
    public var id: UUID = UUID()
    public var canonicalId: String = ""
    public var ynabPayeeId: String? = nil
    public var name: String = ""
    public var sourceName: String = ""
    public var transferAccountId: String? = nil
    public var archived: Bool = false
    public var deletedAtSource: Bool = false
    public var userEdited: Bool = false
    public var createdAt: Date = Date.now
    public var updatedAt: Date = Date.now

    public init(
        id: UUID = UUID(),
        canonicalId: String = "",
        ynabPayeeId: String? = nil,
        name: String = "",
        sourceName: String = "",
        transferAccountId: String? = nil,
        archived: Bool = false,
        deletedAtSource: Bool = false,
        userEdited: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.canonicalId = canonicalId
        self.ynabPayeeId = ynabPayeeId
        self.name = name
        self.sourceName = sourceName
        self.transferAccountId = transferAccountId
        self.archived = archived
        self.deletedAtSource = deletedAtSource
        self.userEdited = userEdited
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// One piece of provider evidence that resolves to a canonical payee. Aliases
/// are many-to-one and never carry category or approval state.
@Model
public final class DurablePayeeAlias {
    public var id: UUID = UUID()
    public var aliasKey: String = ""
    public var payeeCanonicalId: String = ""
    public var displayValue: String = ""
    public var kindRaw: String = ""
    public var institutionName: String? = nil
    public var provenanceRaw: String = ClassificationProvenance.historicalMatch.rawValue
    public var confirmed: Bool = false
    public var suppressed: Bool = false
    public var createdAt: Date = Date.now
    public var updatedAt: Date = Date.now

    public init(
        id: UUID = UUID(),
        aliasKey: String = "",
        payeeCanonicalId: String = "",
        displayValue: String = "",
        kindRaw: String = "",
        institutionName: String? = nil,
        provenance: ClassificationProvenance = .historicalMatch,
        confirmed: Bool = false,
        suppressed: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.aliasKey = aliasKey
        self.payeeCanonicalId = payeeCanonicalId
        self.displayValue = displayValue
        self.kindRaw = kindRaw
        self.institutionName = institutionName
        self.provenanceRaw = provenance.rawValue
        self.confirmed = confirmed
        self.suppressed = suppressed
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Editable category catalog seeded from YNAB. Stable category identity and
/// group identity remain intact even when the user changes their local names.
@Model
public final class DurableCanonicalCategory {
    public var id: UUID = UUID()
    public var canonicalId: String = ""
    public var ynabCategoryId: String? = nil
    public var ynabGroupId: String? = nil
    public var name: String = ""
    public var groupName: String = ""
    public var sourceName: String = ""
    public var sourceGroupName: String = ""
    /// Stable identity of the owning `DurableCategoryGroup`. Additive: nil
    /// means the category has not been assigned to a Networth-owned group.
    public var categoryGroupIdentity: String? = nil
    public var hidden: Bool = false
    public var deletedAtSource: Bool = false
    public var userEdited: Bool = false
    public var createdAt: Date = Date.now
    public var updatedAt: Date = Date.now

    public init(
        id: UUID = UUID(),
        canonicalId: String = "",
        ynabCategoryId: String? = nil,
        ynabGroupId: String? = nil,
        name: String = "",
        groupName: String = "",
        sourceName: String = "",
        sourceGroupName: String = "",
        categoryGroupIdentity: String? = nil,
        hidden: Bool = false,
        deletedAtSource: Bool = false,
        userEdited: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.canonicalId = canonicalId
        self.ynabCategoryId = ynabCategoryId
        self.ynabGroupId = ynabGroupId
        self.name = name
        self.groupName = groupName
        self.sourceName = sourceName
        self.sourceGroupName = sourceGroupName
        self.categoryGroupIdentity = categoryGroupIdentity
        self.hidden = hidden
        self.deletedAtSource = deletedAtSource
        self.userEdited = userEdited
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Networth-owned category-group directory. A group's reporting role decides
/// how its categories' activity is treated in reports: spending groups feed
/// Spending History; income, investment, and transfer groups stay outside
/// spending totals. YNAB may seed initial rows, but names, ordering, color,
/// and visibility belong to Networth afterward. All fields have defaults for
/// additive CloudKit schema compatibility.
@Model
public final class DurableCategoryGroup {
    public var id: UUID = UUID()
    /// Stable identity referenced by category rows; survives renames.
    public var groupIdentity: String = ""
    public var name: String = ""
    public var displayOrder: Int = 0
    public var chartColorHex: String = ""
    public var reportingRoleRaw: String = CategoryReportingRole.spending.rawValue
    public var hidden: Bool = false
    public var createdAt: Date = Date.now
    public var updatedAt: Date = Date.now

    public init(
        id: UUID = UUID(),
        groupIdentity: String = "",
        name: String = "",
        displayOrder: Int = 0,
        chartColorHex: String = "",
        reportingRole: CategoryReportingRole = .spending,
        hidden: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.groupIdentity = groupIdentity
        self.name = name
        self.displayOrder = displayOrder
        self.chartColorHex = chartColorHex
        self.reportingRoleRaw = reportingRole.rawValue
        self.hidden = hidden
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var reportingRole: CategoryReportingRole {
        get { CategoryReportingRole(rawValue: reportingRoleRaw) ?? .spending }
        set { reportingRoleRaw = newValue.rawValue }
    }
}

struct DiscretionaryCategoryOption: Identifiable, Hashable {
    let id: String
    let sourceCategoryId: String?
    let name: String
    let sourceName: String
    let groupName: String
    let hidden: Bool
    let deleted: Bool

    var acceptedIds: Set<String> {
        var values: Set<String> = [id]
        if let sourceCategoryId {
            values.insert(sourceCategoryId)
            values.insert("ynab:\(sourceCategoryId)")
        }
        for candidate in [name, sourceName] where !candidate.isEmpty {
            let normalized = FinancialTransactionSummary
                .normalizedDescription(candidate)
                .replacingOccurrences(of: " ", with: "-")
            values.insert("local:\(normalized)")
        }
        return values
    }

    var acceptedNames: Set<String> {
        Set([name, sourceName].filter { !$0.isEmpty })
    }
}

enum DiscretionaryCategoryResolver {
    static func options(
        canonical: [DurableCanonicalCategory],
        cached: [CachedCategory],
        activeOnly: Bool
    ) -> [DiscretionaryCategoryOption] {
        var byID: [String: DiscretionaryCategoryOption] = [:]
        for category in canonical {
            let option = DiscretionaryCategoryOption(
                id: category.canonicalId,
                sourceCategoryId: category.ynabCategoryId,
                name: category.name,
                sourceName: category.sourceName,
                groupName: category.groupName,
                hidden: category.hidden,
                deleted: category.deletedAtSource
            )
            byID[option.id] = option
        }
        for category in cached {
            let id = "ynab:\(category.id)"
            guard byID[id] == nil else { continue }
            byID[id] = DiscretionaryCategoryOption(
                id: id,
                sourceCategoryId: category.id,
                name: category.name,
                sourceName: category.name,
                groupName: category.groupName,
                hidden: category.hidden,
                deleted: category.deleted
            )
        }
        return byID.values
            .filter {
                !$0.name.isEmpty
                    && (!activeOnly || (!$0.hidden && !$0.deleted))
            }
            .sorted {
                if $0.groupName != $1.groupName {
                    return $0.groupName.localizedCaseInsensitiveCompare(
                        $1.groupName
                    ) == .orderedAscending
                }
                return $0.name.localizedCaseInsensitiveCompare($1.name)
                    == .orderedAscending
            }
    }

    static func selectedIds(
        settings: DurableUserSettings?,
        activeOptions: [DiscretionaryCategoryOption]
    ) -> Set<String> {
        if let settings,
           settings.discretionaryCategoryIdsData != nil {
            return settings.discretionaryCategoryIds
        }
        return Set(activeOptions.filter {
            DiscretionaryBudgetDefaults.includesCategory(
                name: $0.name,
                groupName: $0.groupName
            )
        }.map(\.id))
    }

    static func acceptedCategories(
        selectedIds: Set<String>,
        allOptions: [DiscretionaryCategoryOption]
    ) -> (ids: Set<String>, names: Set<String>) {
        let selectedOptions = allOptions.filter {
            selectedIds.contains($0.id)
        }
        return (
            selectedOptions.reduce(into: selectedIds) {
                $0.formUnion($1.acceptedIds)
            },
            selectedOptions.reduce(into: Set<String>()) {
                $0.formUnion($1.acceptedNames)
            }
        )
    }
}

/// A durable decision for exactly one Plaid transaction. Payee identity,
/// category identity, treatment, splits, and review status are transaction
/// data—not merchant rules.
@Model
public final class DurableCanonicalTransactionDecision {
    public var id: UUID = UUID()
    public var transactionExternalId: String = ""
    public var ynabTransactionId: String? = nil
    public var payeeCanonicalId: String? = nil
    public var payeeNameSnapshot: String = ""
    public var categoryCanonicalId: String? = nil
    public var categoryNameSnapshot: String? = nil
    public var amountSign: Int = 0
    public var forecastTreatmentRaw: String = ForecastTreatment.ordinarySpending.rawValue
    public var subtransactionsData: Data? = nil
    public var reviewed: Bool = false
    public var provenanceRaw: String = ClassificationProvenance.historicalMatch.rawValue
    public var createdAt: Date = Date.now
    public var updatedAt: Date = Date.now

    public init(
        id: UUID = UUID(),
        transactionExternalId: String = "",
        ynabTransactionId: String? = nil,
        payeeCanonicalId: String? = nil,
        payeeNameSnapshot: String = "",
        categoryCanonicalId: String? = nil,
        categoryNameSnapshot: String? = nil,
        amountSign: Int = 0,
        forecastTreatment: ForecastTreatment = .ordinarySpending,
        subtransactionsData: Data? = nil,
        reviewed: Bool = false,
        provenance: ClassificationProvenance = .historicalMatch,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.transactionExternalId = transactionExternalId
        self.ynabTransactionId = ynabTransactionId
        self.payeeCanonicalId = payeeCanonicalId
        self.payeeNameSnapshot = payeeNameSnapshot
        self.categoryCanonicalId = categoryCanonicalId
        self.categoryNameSnapshot = categoryNameSnapshot
        self.amountSign = amountSign
        self.forecastTreatmentRaw = forecastTreatment.rawValue
        self.subtransactionsData = subtransactionsData
        self.reviewed = reviewed
        self.provenanceRaw = provenance.rawValue
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var forecastTreatment: ForecastTreatment {
        get {
            ForecastTreatment(rawValue: forecastTreatmentRaw)
                ?? .ordinarySpending
        }
        set { forecastTreatmentRaw = newValue.rawValue }
    }

    public var subtransactions: [SubTransactionSummary] {
        guard let subtransactionsData, !subtransactionsData.isEmpty else {
            return []
        }
        return (try? JSONDecoder().decode(
            [SubTransactionSummary].self,
            from: subtransactionsData
        )) ?? []
    }
}

/// One row per closed YNAB account the user wants to include in the trend
/// chart's historical reconstruction. Default is to leave closed accounts
/// out (matches the original behavior); the user opts a closed account in
/// when its YNAB history is genuinely relevant to historical net worth
/// (e.g. brokerage staging accounts the user funded then drained).
@Model
public final class DurableIncludedClosedAccount {
    public var accountId: String = ""
    public var canonicalAccountId: String? = nil
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
    public var canonicalAccountId: String? = nil
    public var included: Bool = false

    public init(id: UUID = UUID(), accountId: String = "", included: Bool = false) {
        self.id = id
        self.accountId = accountId
        self.included = included
    }
}

/// Durable identity bridge between provider-specific account IDs and the
/// source-neutral account ID used by settings and projections.
@Model
public final class DurableCanonicalAccountBinding {
    public var id: UUID = UUID()
    public var canonicalAccountId: String = ""
    public var plaidAccountId: String = ""
    public var ynabAccountId: String? = nil
    public var itemId: String = ""
    public var institutionName: String = ""
    public var accountName: String = ""
    public var mask: String? = nil
    public var accountTypeRaw: String = FinancialAccountType.other.rawValue
    public var reviewed: Bool = false
    public var createdAt: Date = Date.now
    public var updatedAt: Date = Date.now

    public init(
        id: UUID = UUID(),
        canonicalAccountId: String = UUID().uuidString,
        plaidAccountId: String = "",
        ynabAccountId: String? = nil,
        itemId: String = "",
        institutionName: String = "",
        accountName: String = "",
        mask: String? = nil,
        accountType: FinancialAccountType = .other,
        reviewed: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.canonicalAccountId = canonicalAccountId
        self.plaidAccountId = plaidAccountId
        self.ynabAccountId = ynabAccountId
        self.itemId = itemId
        self.institutionName = institutionName
        self.accountName = accountName
        self.mask = mask
        self.accountTypeRaw = accountType.rawValue
        self.reviewed = reviewed
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var accountType: FinancialAccountType {
        get { FinancialAccountType(rawValue: accountTypeRaw) ?? .other }
        set { accountTypeRaw = newValue.rawValue }
    }
}

@Model
public final class DurableMerchantRule {
    public var id: UUID = UUID()
    public var fingerprint: String = ""
    public var preferredName: String = ""
    public var categoryRaw: String = NativeTransactionCategory.other.rawValue
    public var categoryName: String? = nil
    public var forecastTreatmentRaw: String = ForecastTreatment.ordinarySpending.rawValue
    public var categoryReusable: Bool = false
    public var ruleSchemaVersion: Int = 0
    public var provenanceRaw: String = ClassificationProvenance.user.rawValue
    public var confirmed: Bool = false
    public var nameConfirmedAt: Date? = nil
    public var createdAt: Date = Date.now
    public var updatedAt: Date = Date.now

    public init(
        id: UUID = UUID(),
        fingerprint: String = "",
        preferredName: String = "",
        category: NativeTransactionCategory = .other,
        categoryName: String? = nil,
        forecastTreatment: ForecastTreatment = .ordinarySpending,
        categoryReusable: Bool = false,
        ruleSchemaVersion: Int = 1,
        provenance: ClassificationProvenance = .user,
        confirmed: Bool = false,
        nameConfirmedAt: Date? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.fingerprint = fingerprint
        self.preferredName = preferredName
        self.categoryRaw = category.rawValue
        self.categoryName = categoryName
        self.forecastTreatmentRaw = forecastTreatment.rawValue
        self.categoryReusable = categoryReusable
        self.ruleSchemaVersion = ruleSchemaVersion
        self.provenanceRaw = provenance.rawValue
        self.confirmed = confirmed
        self.nameConfirmedAt = nameConfirmedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public func toCore() -> MerchantClassificationRule {
        MerchantClassificationRule(
            id: id,
            fingerprint: fingerprint,
            preferredName: preferredName,
            category: NativeTransactionCategory(rawValue: categoryRaw) ?? .other,
            categoryName: categoryName,
            treatment: ForecastTreatment(rawValue: forecastTreatmentRaw) ?? .ordinarySpending,
            categoryReusable: categoryReusable,
            provenance: ClassificationProvenance(rawValue: provenanceRaw) ?? .user,
            confirmed: confirmed
        )
    }
}

/// A user-created category that extends the imported YNAB category list.
@Model
public final class DurableTransactionCategory {
    public var id: UUID = UUID()
    public var name: String = ""
    public var groupName: String = "Networth Categories"
    /// Stable identity of the owning `DurableCategoryGroup`. Additive: nil
    /// means the category has not been assigned to a Networth-owned group.
    public var categoryGroupIdentity: String? = nil
    public var hidden: Bool = false
    public var createdAt: Date = Date.now
    public var updatedAt: Date = Date.now

    public init(
        id: UUID = UUID(),
        name: String,
        groupName: String = "Networth Categories",
        categoryGroupIdentity: String? = nil,
        hidden: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.groupName = groupName
        self.categoryGroupIdentity = categoryGroupIdentity
        self.hidden = hidden
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// One-off correction when the user does not want a change to become a
/// merchant-wide rule.
@Model
public final class DurableTransactionOverride {
    public var id: UUID = UUID()
    public var transactionExternalId: String = ""
    public var displayName: String = ""
    public var categoryRaw: String = NativeTransactionCategory.other.rawValue
    public var categoryName: String? = nil
    public var forecastTreatmentRaw: String = ForecastTreatment.ordinarySpending.rawValue
    public var subtransactionsData: Data? = nil
    public var provenanceRaw: String = ClassificationProvenance.user.rawValue
    public var createdAt: Date = Date.now
    public var updatedAt: Date = Date.now

    public init(
        id: UUID = UUID(),
        transactionExternalId: String = "",
        displayName: String = "",
        category: NativeTransactionCategory = .other,
        categoryName: String? = nil,
        forecastTreatment: ForecastTreatment = .ordinarySpending,
        subtransactionsData: Data? = nil,
        provenance: ClassificationProvenance = .user,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.transactionExternalId = transactionExternalId
        self.displayName = displayName
        self.categoryRaw = category.rawValue
        self.categoryName = categoryName
        self.forecastTreatmentRaw = forecastTreatment.rawValue
        self.subtransactionsData = subtransactionsData
        self.provenanceRaw = provenance.rawValue
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var subtransactions: [SubTransactionSummary] {
        guard let subtransactionsData, !subtransactionsData.isEmpty else {
            return []
        }
        return (try? JSONDecoder().decode(
            [SubTransactionSummary].self,
            from: subtransactionsData
        )) ?? []
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

/// An opt-in sinking fund: money earmarked for a specific future purpose
/// (travel, furniture, car). Backed by real balances wherever they live —
/// nothing outside a fund is ever asked to justify itself. Every field
/// defaults for CloudKit safety.
@Model
public final class DurableSinkingFund {
    public var id: UUID = UUID()
    public var name: String = ""
    /// 0 = open-ended, no target.
    public var targetMilliunits: Int64 = 0
    public var targetDate: Date? = nil
    /// Used only for on-track math; never auto-contributes. 0 = no plan.
    public var plannedMonthlyMilliunits: Int64 = 0
    public var spendModeRaw: String = FundSpendMode.saveToSpend.rawValue
    /// JSON [String] of normalized category-name keys whose spending drains
    /// this fund automatically.
    public var linkedCategoryKeysData: Data? = nil
    /// Linked-category spending before this date never drains the fund.
    public var startDate: Date = Date.now
    public var archived: Bool = false
    public var createdAt: Date = Date.now
    public var updatedAt: Date = Date.now

    public init(
        id: UUID = UUID(),
        name: String = "",
        targetMilliunits: Int64 = 0,
        targetDate: Date? = nil,
        plannedMonthlyMilliunits: Int64 = 0,
        spendMode: FundSpendMode = .saveToSpend,
        linkedCategoryKeys: [String] = [],
        startDate: Date = .now,
        archived: Bool = false
    ) {
        self.id = id
        self.name = name
        self.targetMilliunits = targetMilliunits
        self.targetDate = targetDate
        self.plannedMonthlyMilliunits = plannedMonthlyMilliunits
        self.spendModeRaw = spendMode.rawValue
        self.linkedCategoryKeysData = try? JSONEncoder()
            .encode(linkedCategoryKeys)
        self.startDate = startDate
        self.archived = archived
    }

    public var spendMode: FundSpendMode {
        get { FundSpendMode(rawValue: spendModeRaw) ?? .saveToSpend }
        set { spendModeRaw = newValue.rawValue }
    }

    public var linkedCategoryKeys: [String] {
        get {
            guard let linkedCategoryKeysData else { return [] }
            return (try? JSONDecoder().decode(
                [String].self, from: linkedCategoryKeysData
            )) ?? []
        }
        set {
            linkedCategoryKeysData = try? JSONEncoder().encode(newValue)
        }
    }

    public func toCore() -> SinkingFund {
        SinkingFund(
            id: id.uuidString,
            name: name,
            target: Money(milliunits: targetMilliunits),
            targetDate: targetDate,
            plannedMonthly: Money(milliunits: plannedMonthlyMilliunits),
            spendMode: spendMode,
            linkedCategoryKeys: Set(linkedCategoryKeys),
            startDate: startDate,
            archived: archived
        )
    }
}

/// One explicit fund movement: positive = contribution, negative =
/// withdrawal. The fund balance is the sum of these minus automatic
/// linked-category drains.
@Model
public final class DurableFundEvent {
    public var id: UUID = UUID()
    public var fundId: UUID = UUID()
    public var date: Date = Date.now
    public var amountMilliunits: Int64 = 0
    public var note: String? = nil
    public var createdAt: Date = Date.now

    public init(
        id: UUID = UUID(),
        fundId: UUID = UUID(),
        date: Date = .now,
        amountMilliunits: Int64 = 0,
        note: String? = nil
    ) {
        self.id = id
        self.fundId = fundId
        self.date = date
        self.amountMilliunits = amountMilliunits
        self.note = note
    }

    public func toCore() -> FundLedgerEntry {
        FundLedgerEntry(
            id: id.uuidString,
            fundId: fundId.uuidString,
            date: date,
            amount: Money(milliunits: amountMilliunits),
            note: note
        )
    }
}

/// A user-confirmed fixed commitment for the monthly Budget. Confirmation is
/// always explicit; detection only proposes candidates. Confirmed items stay
/// active until explicitly disabled — missing activity is a quiet stale
/// status, never an auto-disable. Every field defaults for CloudKit safety.
@Model
public final class DurableFixedCommitment {
    public var id: UUID = UUID()
    public var displayName: String = ""
    /// Canonical payee ID when known, otherwise a normalized payee-name key.
    public var payeeKey: String = ""
    /// Optional category scoping; empty matches any category from the payee.
    public var categoryKey: String? = nil
    public var cadenceRaw: String = CommitmentCadence.monthly.rawValue
    public var amountBasisRaw: String =
        CommitmentAmountBasis.latestAmount.rawValue
    /// Positive planned per-occurrence amount. When the user overrides the
    /// suggested amount this stores their value and `userEditedAmount` locks
    /// it against re-detection updates.
    public var amountMilliunits: Int64 = 0
    public var anchorDate: Date = Date.now
    public var active: Bool = true
    public var userEditedAmount: Bool = false
    public var createdAt: Date = Date.now
    public var updatedAt: Date = Date.now

    public init(
        id: UUID = UUID(),
        displayName: String = "",
        payeeKey: String = "",
        categoryKey: String? = nil,
        cadence: CommitmentCadence = .monthly,
        amountBasis: CommitmentAmountBasis = .latestAmount,
        amountMilliunits: Int64 = 0,
        anchorDate: Date = .now,
        active: Bool = true,
        userEditedAmount: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.displayName = displayName
        self.payeeKey = payeeKey
        self.categoryKey = categoryKey
        self.cadenceRaw = cadence.rawValue
        self.amountBasisRaw = amountBasis.rawValue
        self.amountMilliunits = amountMilliunits
        self.anchorDate = anchorDate
        self.active = active
        self.userEditedAmount = userEditedAmount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var cadence: CommitmentCadence {
        get { CommitmentCadence(rawValue: cadenceRaw) ?? .monthly }
        set { cadenceRaw = newValue.rawValue }
    }

    public var amountBasis: CommitmentAmountBasis {
        get { CommitmentAmountBasis(rawValue: amountBasisRaw) ?? .latestAmount }
        set { amountBasisRaw = newValue.rawValue }
    }

    public func toCore() -> FixedCommitment {
        FixedCommitment(
            id: id.uuidString,
            displayName: displayName,
            payeeKey: payeeKey,
            categoryKey: categoryKey?.isEmpty == true ? nil : categoryKey,
            cadence: cadence,
            amountBasis: amountBasis,
            amount: Money(milliunits: amountMilliunits),
            anchorDate: anchorDate,
            active: active
        )
    }
}

/// One reviewed category → budget-bucket assignment. Keys are stable
/// canonical category identities so source renames cannot move categories.
@Model
public final class DurableBudgetCategoryAssignment {
    public var id: UUID = UUID()
    public var categoryKey: String = ""
    /// Display-name snapshot for audit and name-keyed matching of summaries
    /// that lack a canonical identity.
    public var categoryName: String = ""
    public var bucketRaw: String = BudgetBucket.excluded.rawValue
    public var updatedAt: Date = Date.now

    public init(
        id: UUID = UUID(),
        categoryKey: String = "",
        categoryName: String = "",
        bucket: BudgetBucket = .excluded,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.categoryKey = categoryKey
        self.categoryName = categoryName
        self.bucketRaw = bucket.rawValue
        self.updatedAt = updatedAt
    }

    public var bucket: BudgetBucket {
        get { BudgetBucket(rawValue: bucketRaw) ?? .excluded }
        set { bucketRaw = newValue.rawValue }
    }
}

/// The user's confirmed income pattern. Detection proposes; this records the
/// confirmation plus optional overrides so the plan never silently drifts.
@Model
public final class DurableIncomePatternOverride {
    public var id: String = "singleton"
    public var payeeKey: String = ""
    public var displayName: String = ""
    public var cadenceRaw: String = CommitmentCadence.biweekly.rawValue
    public var confirmed: Bool = false
    /// 0 = plan with the detected phase evidence; a positive value pins the
    /// expected per-paycheck take-home instead.
    public var perPaycheckOverrideMilliunits: Int64 = 0
    public var confirmedAt: Date? = nil
    public var updatedAt: Date = Date.now

    public init(id: String = "singleton") { self.id = id }

    public var cadence: CommitmentCadence {
        get { CommitmentCadence(rawValue: cadenceRaw) ?? .biweekly }
        set { cadenceRaw = newValue.rawValue }
    }
}

/// User-authored recurring expectation: the only authoritative dated future
/// events after the Plaid-first clean start. Card payments are never modeled
/// here — the statement/autopay forecaster owns them. All fields defaulted
/// for additive CloudKit schema compatibility.
@Model
public final class DurableRecurringExpectation {
    public var id: UUID = UUID()
    /// Canonical account the activity posts to (cash account or card).
    public var accountCanonicalId: String = ""
    /// Transfer destination; nil for non-transfers.
    public var destinationAccountCanonicalId: String? = nil
    public var payeeName: String = ""
    public var payeeCanonicalId: String? = nil
    public var categoryCanonicalId: String? = nil
    public var categoryName: String? = nil
    public var forecastTreatmentRaw: String = ForecastTreatment.ordinarySpending.rawValue
    public var cadenceRaw: String = CommitmentCadence.monthly.rawValue
    public var nextOccurrenceAt: Date = Date.now
    /// Signed: negative outflow, positive income.
    public var amountMilliunits: Int64 = 0
    public var archived: Bool = false
    public var createdAt: Date = Date.now
    public var updatedAt: Date = Date.now

    public init(
        id: UUID = UUID(),
        accountCanonicalId: String = "",
        destinationAccountCanonicalId: String? = nil,
        payeeName: String = "",
        payeeCanonicalId: String? = nil,
        categoryCanonicalId: String? = nil,
        categoryName: String? = nil,
        forecastTreatment: ForecastTreatment = .ordinarySpending,
        cadence: CommitmentCadence = .monthly,
        nextOccurrenceAt: Date = .now,
        amountMilliunits: Int64 = 0,
        archived: Bool = false
    ) {
        self.id = id
        self.accountCanonicalId = accountCanonicalId
        self.destinationAccountCanonicalId = destinationAccountCanonicalId
        self.payeeName = payeeName
        self.payeeCanonicalId = payeeCanonicalId
        self.categoryCanonicalId = categoryCanonicalId
        self.categoryName = categoryName
        self.forecastTreatmentRaw = forecastTreatment.rawValue
        self.cadenceRaw = cadence.rawValue
        self.nextOccurrenceAt = nextOccurrenceAt
        self.amountMilliunits = amountMilliunits
        self.archived = archived
    }

    public var forecastTreatment: ForecastTreatment {
        get { ForecastTreatment(rawValue: forecastTreatmentRaw) ?? .ordinarySpending }
        set { forecastTreatmentRaw = newValue.rawValue }
    }

    public var cadence: CommitmentCadence {
        get { CommitmentCadence(rawValue: cadenceRaw) ?? .monthly }
        set { cadenceRaw = newValue.rawValue }
    }

    public var amount: Money { Money(milliunits: amountMilliunits) }

    public func toCore() -> RecurringExpectation {
        RecurringExpectation(
            id: id.uuidString,
            accountId: accountCanonicalId,
            destinationAccountId: destinationAccountCanonicalId,
            payeeName: payeeName,
            payeeCanonicalId: payeeCanonicalId,
            categoryCanonicalId: categoryCanonicalId,
            categoryName: categoryName,
            treatment: forecastTreatment,
            cadence: cadence,
            nextOccurrence: nextOccurrenceAt,
            amount: amount
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
