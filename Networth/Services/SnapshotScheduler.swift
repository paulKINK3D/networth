import Foundation
import SwiftData
import os
import NetworthCore

public struct SharedIBRLoanSnapshot: Codable, Sendable, Hashable, Identifiable {
    public var id: Date { asOf }
    public let asOf: Date
    public let principalMilliunits: Int64
    public let accruedInterestMilliunits: Int64
    public let weightedInterestRatePercent: Decimal?
    public let actualMonthlyPaymentMilliunits: Int64?
    public let servicerName: String?
    public let forgivenessDate: Date
    public let qualifyingPayments: Int
    public let forgivenessThreshold: Int

    public init(
        asOf: Date,
        principalMilliunits: Int64,
        accruedInterestMilliunits: Int64,
        weightedInterestRatePercent: Decimal? = nil,
        actualMonthlyPaymentMilliunits: Int64? = nil,
        servicerName: String? = nil,
        forgivenessDate: Date,
        qualifyingPayments: Int,
        forgivenessThreshold: Int
    ) {
        self.asOf = asOf
        self.principalMilliunits = principalMilliunits
        self.accruedInterestMilliunits = accruedInterestMilliunits
        self.weightedInterestRatePercent = weightedInterestRatePercent
        self.actualMonthlyPaymentMilliunits = actualMonthlyPaymentMilliunits
        self.servicerName = servicerName
        self.forgivenessDate = forgivenessDate
        self.qualifyingPayments = qualifyingPayments
        self.forgivenessThreshold = forgivenessThreshold
    }

    public var principal: Money { Money(milliunits: principalMilliunits) }
    public var accruedInterest: Money { Money(milliunits: accruedInterestMilliunits) }
    public var totalBalance: Money { principal + accruedInterest }
    public var actualMonthlyPayment: Money? {
        actualMonthlyPaymentMilliunits.map(Money.init(milliunits:))
    }
    public var paymentsRemaining: Int { max(0, forgivenessThreshold - qualifyingPayments) }
}

public struct SharedIBRLoanDocument: Codable, Sendable, Hashable {
    public let schemaVersion: Int
    public let writtenAt: Date
    public let current: SharedIBRLoanSnapshot
    public let history: [SharedIBRLoanSnapshot]

    public init(
        schemaVersion: Int = 1,
        writtenAt: Date = .now,
        current: SharedIBRLoanSnapshot,
        history: [SharedIBRLoanSnapshot]
    ) {
        self.schemaVersion = schemaVersion
        self.writtenAt = writtenAt
        self.current = current
        self.history = history
    }

    public func balance(
        on date: Date,
        calendar: Calendar = .current,
        historyStartDate: Date? = nil
    ) -> Money {
        let day = calendar.startOfDay(for: date)
        let sortedHistory = history.sorted { $0.asOf < $1.asOf }
        guard let earliest = sortedHistory.first else { return .zero }
        let startDay = calendar.startOfDay(for: historyStartDate ?? earliest.asOf)
        guard day >= startDay else { return .zero }

        if let datedBalance = sortedHistory
            .filter({ calendar.startOfDay(for: $0.asOf) <= day })
            .max(by: { $0.asOf < $1.asOf }) {
            return datedBalance.totalBalance
        }

        let sharedRate = earliest.weightedInterestRatePercent
            ?? sortedHistory.compactMap(\.weightedInterestRatePercent).first
            ?? current.weightedInterestRatePercent
        guard let ratePercent = sharedRate,
              ratePercent > 0 else {
            return earliest.totalBalance
        }
        let anchorDay = calendar.startOfDay(for: earliest.asOf)
        let days = max(0, calendar.dateComponents([.day], from: day, to: anchorDay).day ?? 0)
        let accruedSinceDate = earliest.principal.scaled(
            by: (ratePercent / 100) * Decimal(days) / 365
        )
        let estimatedAccrued = max(.zero, earliest.accruedInterest - accruedSinceDate)
        return earliest.principal + estimatedAccrued
    }
}

public protocol IBRLoanStore: Sendable {
    func load() throws -> SharedIBRLoanDocument?
}

public struct AppGroupIBRLoanStore: IBRLoanStore {
    public static let appGroupIdentifier = "group.com.bluelava.me.financial"
    public static let fileName = "ibr-loan-summary-v1.json"

    public init() {}

    public func load() throws -> SharedIBRLoanDocument? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier
        ) else {
            return nil
        }
        let url = container.appendingPathComponent(Self.fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(SharedIBRLoanDocument.self, from: data)
        guard document.schemaVersion == 1 else { return nil }
        return document
    }
}

public struct InMemoryIBRLoanStore: IBRLoanStore {
    public let document: SharedIBRLoanDocument?

    public init(document: SharedIBRLoanDocument? = nil) {
        self.document = document
    }

    public func load() throws -> SharedIBRLoanDocument? { document }
}

public protocol IBRLoanHistorySettingsStore {
    func loadStartDate() -> Date?
    func saveStartDate(_ date: Date?)
}

public struct UserDefaultsIBRLoanHistorySettingsStore: IBRLoanHistorySettingsStore {
    public static let startDateKey = "networth.ibrLoanHistoryStartDate.v2"

    public init() {}

    public func loadStartDate() -> Date? {
        let interval = UserDefaults.standard.double(forKey: Self.startDateKey)
        return interval > 0 ? Date(timeIntervalSince1970: interval) : nil
    }

    public func saveStartDate(_ date: Date?) {
        if let date {
            UserDefaults.standard.set(date.timeIntervalSince1970, forKey: Self.startDateKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.startDateKey)
        }
    }
}

public final class InMemoryIBRLoanHistorySettingsStore: IBRLoanHistorySettingsStore {
    public var startDate: Date?

    public init(startDate: Date? = nil) {
        self.startDate = startDate
    }

    public func loadStartDate() -> Date? { startDate }
    public func saveStartDate(_ date: Date?) { startDate = date }
}

/// Records a daily net-worth snapshot from current cached YNAB balances and
/// the latest known manual-asset values. Idempotent within a single day.
@MainActor
public final class SnapshotScheduler {
    private let mainContext: ModelContext
    private let calendar: Calendar
    private let logger = Logger(subsystem: "com.bluelava.me.networth", category: "snapshot")

    public init(mainContext: ModelContext, calendar: Calendar = .current) {
        self.mainContext = mainContext
        self.calendar = calendar
    }

    /// Writes (or refreshes) a snapshot for `referenceDate`'s start-of-day.
    /// If a snapshot already exists for today and the freshly computed assets
    /// or liabilities differ, the existing row is **updated in place** rather
    /// than skipped — otherwise today's value would lag behind newly added
    /// manual assets, freshly synced YNAB balances, etc.
    @discardableResult
    public func recordIfNeeded(now referenceDate: Date = .now) -> DurableNetWorthSnapshot? {
        let day = calendar.startOfDay(for: referenceDate)

        // After the Plaid-first clean start, Net Worth history begins with
        // the first successful Plaid sync and is never reconstructed. Nothing
        // records before that — not even manual assets entered ahead of the
        // first sync — so day one reflects a synced position.
        let settings = try? mainContext.fetch(
            FetchDescriptor<DurableUserSettings>()
        ).first
        guard settings?.firstPlaidSyncCompletedAt != nil else { return nil }

        // Don't write a zero-valued .live row before any data exists. The app
        // records a snapshot on bootstrap and every activation, so on a brand-
        // new install (no token, no manual assets, no sync yet) this path runs
        // immediately and would otherwise stamp today as $0. The backfill skips
        // `.live` days, so that bogus zero would survive the first real sync.
        guard hasContributingData() else { return nil }

        let breakdown = computeBreakdown()
        let newAssets = breakdown.totalAssets.milliunits
        let newLiabilities = breakdown.totalLiabilities.milliunits

        let descriptor = FetchDescriptor<DurableNetWorthSnapshot>(
            predicate: #Predicate { $0.date == day }
        )
        if let existingRows = try? mainContext.fetch(descriptor), !existingRows.isEmpty {
            // Update the freshest live row in place; drop everything else for
            // this day so the chart can't render the same date with multiple
            // overlapping marks (the vertical spike pattern).
            let sorted = existingRows.sorted { lhs, rhs in
                if lhs.source != rhs.source { return lhs.source == .live }
                return lhs.createdAt > rhs.createdAt
            }
            let survivor = sorted.first!
            var changed = sorted.count > 1
            for row in sorted.dropFirst() { mainContext.delete(row) }
            if survivor.assetsMilliunits != newAssets ||
               survivor.liabilitiesMilliunits != newLiabilities ||
               survivor.source != .live {
                survivor.assetsMilliunits = newAssets
                survivor.liabilitiesMilliunits = newLiabilities
                survivor.sourceRaw = SnapshotSource.live.rawValue
                changed = true
            }
            // An unchanged snapshot must not save: the save notification
            // would immediately make the visible tab recompute the very
            // numbers this method just derived.
            guard changed else { return survivor }
            mainContext.safeSave(source: "snapshot.daily.refresh")
            return survivor
        }

        let snap = DurableNetWorthSnapshot(
            date: day,
            assetsMilliunits: newAssets,
            liabilitiesMilliunits: newLiabilities,
            source: .live
        )
        mainContext.insert(snap)
        dedupeSnapshotsForDuplicateDays()
        mainContext.safeSave(source: "snapshot.daily")
        return snap
    }

    /// Persists at most one Plaid observation per account for the current day.
    /// Accounts that were previously contributing but no longer are receive an
    /// inactive end marker. Earlier observations are never removed, so unlinking
    /// an Item cannot erase the chart's historical values.
    @discardableResult
    public func recordPlaidBalancesIfNeeded(now referenceDate: Date = .now) -> Bool {
        let day = calendar.startOfDay(for: referenceDate)

        do {
            let accounts = try mainContext.fetch(FetchDescriptor<CachedPlaidAccount>())
            let treatments = try mainContext.fetch(
                FetchDescriptor<DurablePlaidAccountTreatment>()
            )
            let manualAssets = try mainContext.fetch(FetchDescriptor<DurableManualAsset>())
            let existing = try mainContext.fetch(
                FetchDescriptor<DurablePlaidBalanceSnapshot>()
            )
            let resolver = PlaidContributionResolver(
                plaidAccounts: accounts,
                treatments: treatments,
                manualAssets: manualAssets
            )
            let contributors = resolver.contributingPlaidAccounts
            let activeAccountIDs = Set(contributors.map(\.id))

            var rowsByAccountAndDay: [String: [DurablePlaidBalanceSnapshot]] = [:]
            var latestByAccountID: [String: DurablePlaidBalanceSnapshot] = [:]
            for row in existing {
                if calendar.startOfDay(for: row.date) == day {
                    rowsByAccountAndDay[row.plaidAccountId, default: []].append(row)
                }
                if let latest = latestByAccountID[row.plaidAccountId] {
                    if row.date > latest.date
                        || (row.date == latest.date && row.recordedAt > latest.recordedAt) {
                        latestByAccountID[row.plaidAccountId] = row
                    }
                } else {
                    latestByAccountID[row.plaidAccountId] = row
                }
            }

            for account in contributors {
                guard let balance = account.currentBalance else { continue }
                let row = freshestRow(
                    from: rowsByAccountAndDay[account.id] ?? [],
                    deletingDuplicates: true
                ) ?? {
                    let inserted = DurablePlaidBalanceSnapshot(
                        plaidAccountId: account.id,
                        date: day
                    )
                    mainContext.insert(inserted)
                    return inserted
                }()
                row.matchedManualAssetId = resolver.matchedManualAssetID(for: account)
                row.date = day
                row.balanceMilliunits = balance.milliunits
                row.active = true
                row.recordedAt = referenceDate
            }

            for (accountID, latest) in latestByAccountID
            where !activeAccountIDs.contains(accountID) && latest.active {
                let row = freshestRow(
                    from: rowsByAccountAndDay[accountID] ?? [],
                    deletingDuplicates: true
                ) ?? {
                    let inserted = DurablePlaidBalanceSnapshot(
                        plaidAccountId: accountID,
                        date: day
                    )
                    mainContext.insert(inserted)
                    return inserted
                }()
                row.matchedManualAssetId = latest.matchedManualAssetId
                row.date = day
                row.balanceMilliunits = latest.balanceMilliunits
                row.active = false
                row.recordedAt = referenceDate
            }

            guard mainContext.safeSave(source: "snapshot.plaid.daily") else {
                mainContext.rollback()
                return false
            }
            return true
        } catch {
            logger.error("Plaid balance history could not be prepared: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func freshestRow(
        from rows: [DurablePlaidBalanceSnapshot],
        deletingDuplicates: Bool
    ) -> DurablePlaidBalanceSnapshot? {
        let sorted = rows.sorted { lhs, rhs in
            if lhs.recordedAt != rhs.recordedAt { return lhs.recordedAt > rhs.recordedAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        guard let survivor = sorted.first else { return nil }
        if deletingDuplicates {
            for duplicate in sorted.dropFirst() {
                mainContext.delete(duplicate)
            }
        }
        return survivor
    }

    /// Collapses multiple snapshots sharing the same start-of-day. Tiebreak:
    /// `.live` always wins over `.backfill` (live includes manual assets);
    /// then highest `createdAt` (freshest write); then lexically-lowest UUID
    /// for the rare case where source and timestamp tie.
    ///
    /// Safe to call any time — when there are no duplicates, this is just one
    /// fetch and a group-by, no writes. Save is the caller's responsibility.
    public func dedupeSnapshotsForDuplicateDays() {
        let descriptor = FetchDescriptor<DurableNetWorthSnapshot>()
        guard let all = try? mainContext.fetch(descriptor), !all.isEmpty else { return }

        let groups = Dictionary(grouping: all) { calendar.startOfDay(for: $0.date) }
        for (_, rows) in groups where rows.count > 1 {
            let survivor = rows.sorted { lhs, rhs in
                if lhs.source != rhs.source {
                    return lhs.source == .live
                }
                if lhs.createdAt != rhs.createdAt {
                    return lhs.createdAt > rhs.createdAt
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }.first!
            for row in rows where row.id != survivor.id {
                mainContext.delete(row)
            }
        }
    }

    /// True when at least one connected account or manual asset exists in the
    /// store — i.e. there is real data that could contribute non-zero values
    /// to today's snapshot.
    private func hasContributingData() -> Bool {
        var financialDescriptor = FetchDescriptor<CachedFinancialAccount>(
            predicate: #Predicate { $0.deleted == false }
        )
        financialDescriptor.fetchLimit = 1
        if let count = try? mainContext.fetchCount(financialDescriptor), count > 0 {
            return true
        }
        var manualDescriptor = FetchDescriptor<DurableManualAsset>(
            predicate: #Predicate { $0.deleted == false }
        )
        manualDescriptor.fetchLimit = 1
        if let count = try? mainContext.fetchCount(manualDescriptor), count > 0 {
            return true
        }
        let treatments = (try? mainContext.fetch(FetchDescriptor<DurablePlaidAccountTreatment>())) ?? []
        let includedIDs = Set(treatments.compactMap {
            $0.treatment.contributesToNetWorth ? $0.plaidAccountId : nil
        })
        if !includedIDs.isEmpty {
            let plaidAccounts = (try? mainContext.fetch(FetchDescriptor<CachedPlaidAccount>())) ?? []
            if plaidAccounts.contains(where: {
                includedIDs.contains($0.id) && plaidAccountCanContribute($0)
            }) {
                return true
            }
        }
        return false
    }

    public func computeBreakdown(
        linkedIBRLoan: SharedIBRLoanSnapshot? = nil
    ) -> NetWorthBreakdown {
        Self.computeBreakdown(
            context: mainContext, linkedIBRLoan: linkedIBRLoan
        )
    }

    /// Context-agnostic breakdown so background model actors can compute it
    /// off the main thread with their own contexts.
    public nonisolated static func computeBreakdown(
        context: ModelContext,
        linkedIBRLoan: SharedIBRLoanSnapshot? = nil
    ) -> NetWorthBreakdown {
        var cash = Money.zero
        var investments = Money.zero
        var retirement = Money.zero
        var otherAssets = Money.zero
        var cardDebt = Money.zero
        var loans = Money.zero
        var otherLiabs = Money.zero

        let financialAccounts = (try? context.fetch(
            FetchDescriptor<CachedFinancialAccount>(
                predicate: #Predicate { $0.deleted == false }
            )
        )) ?? []
        for account in financialAccounts {
            let balance = account.balance
            switch account.type {
            case .checking, .savings, .cash:
                cash += balance
            case .creditCard:
                cardDebt += balance.absolute
            case .investment:
                investments += balance
            case .loan:
                loans += balance.absolute
            case .other:
                if balance.isNegative {
                    otherLiabs += balance.absolute
                } else {
                    otherAssets += balance
                }
            }
        }

        let manualDescriptor = FetchDescriptor<DurableManualAsset>(
            predicate: #Predicate { $0.deleted == false }
        )
        let manual = (try? context.fetch(manualDescriptor)) ?? []
        let treatments = (try? context.fetch(
            FetchDescriptor<DurablePlaidAccountTreatment>()
        )) ?? []
        let plaidAccounts = (try? context.fetch(
            FetchDescriptor<CachedPlaidAccount>()
        )) ?? []
        let plaidResolver = PlaidContributionResolver(
            plaidAccounts: plaidAccounts,
            treatments: treatments,
            manualAssets: manual
        )
        var manualAssets = Money.zero
        for asset in manual {
            // A matched manual asset keeps its user-selected classification;
            // Plaid supplies only the effective live value.
            let value = plaidResolver.effectiveValue(for: asset)
            switch asset.kind {
            case .brokerage, .crypto:
                // Investment-style manual assets contribute to the Investments
                // tile alongside YNAB investment accounts.
                investments += value
            case .retirement:
                retirement += value
            case .realEstate, .vehicle, .collectible:
                // Tangible items live in the Manual Assets tile.
                manualAssets += value
            case .other:
                // "Other" semantically belongs alongside YNAB .otherAsset.
                otherAssets += value
            }
        }

        for account in plaidResolver.standalonePlaidAccounts {
            guard let balance = account.currentBalance else { continue }
            if PlaidRetirementClassifier.isRetirement(subtype: account.subtype) {
                retirement += balance
            } else {
                investments += balance
            }
        }

        if let linkedIBRLoan {
            loans += linkedIBRLoan.totalBalance
        }

        return NetWorthBreakdown(
            cash: cash,
            investments: investments,
            retirement: retirement,
            otherAssets: otherAssets,
            manualAssets: manualAssets,
            creditCardDebt: cardDebt,
            loans: loans,
            otherLiabilities: otherLiabs
        )
    }

    private func plaidAccountCanContribute(_ account: CachedPlaidAccount) -> Bool {
        account.unofficialCurrencyCode == nil
            && account.isoCurrencyCode?.uppercased() == "USD"
            && account.currentBalance != nil
    }

}
