import Foundation
import SwiftData
import os
import NetworthCore

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
        let breakdown = computeBreakdown()
        let newAssets = breakdown.totalAssets.milliunits
        let newLiabilities = breakdown.totalLiabilities.milliunits

        let descriptor = FetchDescriptor<DurableNetWorthSnapshot>(
            predicate: #Predicate { $0.date == day }
        )
        if let existing = try? mainContext.fetch(descriptor).first {
            // Skip the write only if nothing about today's totals has changed.
            if existing.assetsMilliunits == newAssets,
               existing.liabilitiesMilliunits == newLiabilities,
               existing.source == .live {
                return existing
            }
            existing.assetsMilliunits = newAssets
            existing.liabilitiesMilliunits = newLiabilities
            existing.sourceRaw = SnapshotSource.live.rawValue
            mainContext.safeSave(source: "snapshot.daily.refresh")
            return existing
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

    public func computeBreakdown() -> NetWorthBreakdown {
        var cash = Money.zero
        var investments = Money.zero
        var otherAssets = Money.zero
        var cardDebt = Money.zero
        var loans = Money.zero
        var otherLiabs = Money.zero

        let accountDescriptor = FetchDescriptor<CachedAccount>(
            predicate: #Predicate { $0.deleted == false && $0.closed == false }
        )
        let accounts = (try? mainContext.fetch(accountDescriptor)) ?? []
        for account in accounts {
            let kind = account.kind
            let balance = account.balance
            switch kind {
            case .checking, .savings, .cash:
                cash += balance
            case .investment:
                investments += balance
            case .otherAsset:
                otherAssets += balance
            case .creditCard, .lineOfCredit:
                cardDebt += balance.absolute
            case .mortgage, .autoLoan, .studentLoan, .personalLoan, .medicalDebt, .otherDebt:
                loans += balance.absolute
            case .otherLiability:
                otherLiabs += balance.absolute
            case .unknown:
                break
            }
        }

        let manualDescriptor = FetchDescriptor<DurableManualAsset>(
            predicate: #Predicate { $0.deleted == false }
        )
        let manual = (try? mainContext.fetch(manualDescriptor)) ?? []
        var manualAssets = Money.zero
        for asset in manual {
            let value = Money(milliunits: asset.currentValueMilliunits)
            switch asset.kind {
            case .brokerage, .retirement, .crypto:
                // Investment-style manual assets contribute to the Investments
                // tile alongside YNAB investment accounts.
                investments += value
            case .realEstate, .vehicle, .collectible:
                // Tangible items live in the Manual Assets tile.
                manualAssets += value
            case .other:
                // "Other" semantically belongs alongside YNAB .otherAsset.
                otherAssets += value
            }
        }

        return NetWorthBreakdown(
            cash: cash,
            investments: investments,
            otherAssets: otherAssets,
            manualAssets: manualAssets,
            creditCardDebt: cardDebt,
            loans: loans,
            otherLiabilities: otherLiabs
        )
    }
}
