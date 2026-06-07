import Foundation
import SwiftData
import os
import NetworthCore

/// Records a daily net-worth snapshot from current cached YNAB balances and
/// the latest known manual-asset values. Idempotent within a single day.
@MainActor
public final class SnapshotScheduler {
    private let cacheContext: ModelContext
    private let durableContext: ModelContext
    private let calendar: Calendar
    private let logger = Logger(subsystem: "com.bluelava.me.networth", category: "snapshot")

    public init(cacheContext: ModelContext, durableContext: ModelContext, calendar: Calendar = .current) {
        self.cacheContext = cacheContext
        self.durableContext = durableContext
        self.calendar = calendar
    }

    /// Writes a snapshot for `referenceDate`'s start-of-day if one doesn't already exist.
    @discardableResult
    public func recordIfNeeded(now referenceDate: Date = .now) -> DurableNetWorthSnapshot? {
        let day = calendar.startOfDay(for: referenceDate)
        let descriptor = FetchDescriptor<DurableNetWorthSnapshot>(
            predicate: #Predicate { $0.date == day }
        )
        if let existing = try? durableContext.fetch(descriptor).first {
            return existing
        }

        let breakdown = computeBreakdown()
        let snap = DurableNetWorthSnapshot(
            date: day,
            assetsMilliunits: breakdown.totalAssets.milliunits,
            liabilitiesMilliunits: breakdown.totalLiabilities.milliunits,
            source: .live
        )
        durableContext.insert(snap)
        dedupeSnapshotsForDuplicateDays()
        durableContext.safeSave(source: "snapshot.daily")
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
        guard let all = try? durableContext.fetch(descriptor), !all.isEmpty else { return }

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
                durableContext.delete(row)
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
        let accounts = (try? cacheContext.fetch(accountDescriptor)) ?? []
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
        let manual = (try? durableContext.fetch(manualDescriptor)) ?? []
        let manualTotal = Money(milliunits: manual.reduce(Int64(0)) { $0 + $1.currentValueMilliunits })

        return NetWorthBreakdown(
            cash: cash,
            investments: investments,
            otherAssets: otherAssets,
            manualAssets: manualTotal,
            creditCardDebt: cardDebt,
            loans: loans,
            otherLiabilities: otherLiabs
        )
    }
}
