import Foundation
import SwiftData
import NetworthCore

/// Resolves one reserve account's conservative balance from either the
/// source-neutral cash record or the Plaid investments record (taxable
/// brokerage). Shared by the main-actor service and the off-main build actor,
/// so the pool total agrees everywhere. `nil` = account missing/deleted,
/// which the caller treats as zero (surfacing a shortfall).
enum ReserveBalance {
    static func conservative(
        canonicalAccountId: String,
        financialById: [String: CachedFinancialAccount],
        plaidById: [String: CachedPlaidAccount]
    ) -> Money? {
        if let account = financialById[canonicalAccountId],
           !account.deleted,
           let current = account.currentBalanceMilliunits {
            let value = account.availableBalanceMilliunits
                .map { min($0, current) } ?? current
            return Money(milliunits: max(0, value))
        }
        // Investment accounts have no "available" balance; market value is
        // the conservative figure. Volatility surfaces honestly as a
        // shortfall if the balance later drops below allocations.
        if let plaid = plaidById[canonicalAccountId],
           let current = plaid.currentBalanceMilliunits {
            let value = plaid.availableBalanceMilliunits
                .map { min($0, current) } ?? current
            return Money(milliunits: max(0, value))
        }
        return nil
    }
}

/// The single write path for goals, goal ledger entries, and reserve-account
/// selection. Every mutation re-fetches current state, validates the money
/// invariants, then saves or rolls back — no sheet validates independently.
///
/// Invariants owned here:
/// - A contribution source transaction is consumable once, app-wide.
/// - Purchase assignments never exceed a transaction's adjustable amount.
/// - Goal balances never go negative — including via deletes and edits.
/// - Allocations respect the reserve pool (blocked during shortfall).
/// - Archive/complete with a positive balance requires an explicit
///   disposition: release to unallocated, or transfer to another goal
///   (atomic reallocation pair).
@MainActor
struct GoalLedgerService {
    let context: ModelContext

    enum Failure: LocalizedError, Equatable {
        case saveFailed
        case goalInactive
        case balanceWouldGoNegative(Money)
        case exceedsUnallocated(Money)
        case poolInShortfall
        case transactionAlreadyContributed
        case exceedsAdjustableAmount(Money)
        case remainderNeedsDisposition(Money)
        case transferTargetInactive

        var errorDescription: String? {
            switch self {
            case .saveFailed:
                "The change couldn't be saved. Nothing was changed."
            case .goalInactive:
                "This goal is archived or completed."
            case .balanceWouldGoNegative(let balance):
                "This would leave the goal below zero (balance \(CurrencyFormatter.currency(balance)))."
            case .exceedsUnallocated(let unallocated):
                "Only \(CurrencyFormatter.currency(unallocated)) of the reserve is unallocated."
            case .poolInShortfall:
                "The reserve pool is short of its allocations. Resolve the shortfall before allocating more."
            case .transactionAlreadyContributed:
                "This transfer is already logged as a contribution."
            case .exceedsAdjustableAmount(let ceiling):
                "Only \(CurrencyFormatter.currency(ceiling)) of this transaction is assignable spending."
            case .remainderNeedsDisposition(let balance):
                "This goal still holds \(CurrencyFormatter.currency(balance)). Release it or move it to another goal first."
            case .transferTargetInactive:
                "The receiving goal is archived or completed."
            }
        }
    }

    /// What to do with a positive balance when archiving or completing.
    enum RemainderDisposition {
        /// Withdrawal entry: the money returns to unallocated.
        case release
        /// Atomic reallocation pair into another active goal.
        case transfer(to: DurableGoal)
    }

    // MARK: - State reads (shared by validations)

    private func allGoals() throws -> [DurableGoal] {
        try context.fetch(FetchDescriptor<DurableGoal>())
    }

    private func allEntries() throws -> [DurableGoalLedgerEntry] {
        try context.fetch(FetchDescriptor<DurableGoalLedgerEntry>())
    }

    private func balance(
        of goalId: UUID, entries: [DurableGoalLedgerEntry]
    ) -> Money {
        Money(milliunits: entries
            .filter { $0.goalId == goalId }
            .reduce(Int64(0)) { $0 + $1.amountMilliunits }
        )
    }

    /// Conservative combined balance of the active reserve accounts. A
    /// missing or deleted account contributes zero (which surfaces a
    /// shortfall).
    func reservePoolBalance() throws -> Money {
        let reserves = try context.fetch(
            FetchDescriptor<DurableGoalReserveAccount>()
        ).filter(\.active)
        guard !reserves.isEmpty else { return .zero }
        let financialById = Dictionary(
            try context.fetch(FetchDescriptor<CachedFinancialAccount>())
                .map { ($0.canonicalAccountId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let plaidById = Dictionary(
            try context.fetch(FetchDescriptor<CachedPlaidAccount>())
                .map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let total = reserves.reduce(Int64(0)) { sum, reserve in
            sum + (ReserveBalance.conservative(
                canonicalAccountId: reserve.canonicalAccountId,
                financialById: financialById,
                plaidById: plaidById
            )?.milliunits ?? 0)
        }
        return Money(milliunits: total)
    }

    func poolSummary() throws -> ReservePoolSummary {
        let entries = try allEntries()
        let activeBalances = try allGoals()
            .filter { $0.toCore().isActive }
            .map { balance(of: $0.id, entries: entries) }
        return ReservePoolMath.summary(
            reserveBalance: try reservePoolBalance(),
            activeGoalBalances: activeBalances
        )
    }

    // MARK: - Goal lifecycle

    @discardableResult
    func createGoal(
        name: String,
        kind: GoalKind,
        targetMode: GoalTargetMode = .fixed,
        target: Money = .zero,
        targetDate: Date? = nil,
        plannedMonthly: Money = .zero,
        emergencyMonths: Int = 0,
        emergencyReductionPercent: Int = 100
    ) throws -> DurableGoal {
        let goal = DurableGoal(
            name: name,
            kind: kind,
            targetMode: targetMode,
            targetMilliunits: target.milliunits,
            targetDate: targetDate,
            plannedMonthlyMilliunits: plannedMonthly.milliunits,
            emergencyMonths: emergencyMonths,
            emergencyReductionPercent: emergencyReductionPercent
        )
        context.insert(goal)
        try save(source: "goals.create")
        return goal
    }

    func updateGoal(
        _ goal: DurableGoal,
        name: String,
        kind: GoalKind,
        targetMode: GoalTargetMode,
        target: Money,
        targetDate: Date?,
        plannedMonthly: Money,
        emergencyMonths: Int,
        emergencyReductionPercent: Int
    ) throws {
        goal.name = name
        goal.kind = kind
        goal.targetMode = targetMode
        goal.targetMilliunits = target.milliunits
        goal.targetDate = targetDate
        goal.plannedMonthlyMilliunits = plannedMonthly.milliunits
        goal.emergencyMonths = emergencyMonths
        goal.emergencyReductionPercent = emergencyReductionPercent
        goal.updatedAt = .now
        try save(source: "goals.update")
    }

    /// Adopt a newly derived emergency target (hysteresis already applied by
    /// the caller via `EmergencyFundMath.shouldAdopt`).
    func adoptEmergencyTarget(_ goal: DurableGoal, target: Money) throws {
        goal.targetMilliunits = target.milliunits
        goal.adoptedAt = .now
        goal.updatedAt = .now
        try save(source: "goals.adoptTarget")
    }

    func archiveGoal(
        _ goal: DurableGoal,
        remainder: RemainderDisposition?
    ) throws {
        try closeOut(
            goal, remainder: remainder, source: "goals.archive"
        ) { $0.archived = true }
    }

    func completeGoal(
        _ goal: DurableGoal,
        remainder: RemainderDisposition?
    ) throws {
        try closeOut(
            goal, remainder: remainder, source: "goals.complete"
        ) { $0.completedAt = .now }
    }

    private func closeOut(
        _ goal: DurableGoal,
        remainder: RemainderDisposition?,
        source: String,
        apply: (DurableGoal) -> Void
    ) throws {
        let entries = try allEntries()
        let current = balance(of: goal.id, entries: entries)
        if current.milliunits > 0 {
            switch remainder {
            case nil:
                throw Failure.remainderNeedsDisposition(current)
            case .release:
                context.insert(DurableGoalLedgerEntry(
                    goalId: goal.id,
                    date: .now,
                    amountMilliunits: -current.milliunits,
                    kind: .withdrawal,
                    note: "Released on archive"
                ))
            case .transfer(let target):
                guard target.toCore().isActive, target.id != goal.id else {
                    throw Failure.transferTargetInactive
                }
                // Atomic pair: net-zero across the pool, excluded from MTD.
                context.insert(DurableGoalLedgerEntry(
                    goalId: goal.id,
                    date: .now,
                    amountMilliunits: -current.milliunits,
                    kind: .reallocationOut
                ))
                context.insert(DurableGoalLedgerEntry(
                    goalId: target.id,
                    date: .now,
                    amountMilliunits: current.milliunits,
                    kind: .reallocationIn
                ))
            }
        }
        apply(goal)
        goal.updatedAt = .now
        try save(source: source)
    }

    func reopenGoal(_ goal: DurableGoal) throws {
        goal.archived = false
        goal.completedAt = nil
        goal.updatedAt = .now
        try save(source: "goals.reopen")
    }

    // MARK: - Ledger mutations

    /// Manual adjustment. Positive amounts are allocations (validated against
    /// the unallocated pool); negative amounts are validated against the
    /// goal balance.
    func addManualEntry(
        goal: DurableGoal,
        amount: Money,
        date: Date,
        note: String?
    ) throws {
        try validateGoalActive(goal)
        if amount.milliunits > 0 {
            try validateAllocation(amount)
        } else {
            try validateDrawdown(goal: goal, magnitude: amount.absolute)
        }
        context.insert(DurableGoalLedgerEntry(
            goalId: goal.id,
            date: date,
            amountMilliunits: amount.milliunits,
            kind: .manual,
            note: note
        ))
        try save(source: "goals.manualEntry")
    }

    /// Confirm a savings-transfer suggestion into a goal. The source
    /// transaction is consumable once, app-wide, independent of goal.
    /// Move money between two goals directly (envelope reallocation), written
    /// as an atomic net-zero pair.
    func moveBetweenGoals(
        from source: DurableGoal,
        to target: DurableGoal,
        amount: Money
    ) throws {
        try validateGoalActive(source)
        try validateGoalActive(target)
        guard source.id != target.id, amount.milliunits > 0 else { return }
        try validateDrawdown(goal: source, magnitude: amount)
        context.insert(DurableGoalLedgerEntry(
            goalId: source.id, date: .now,
            amountMilliunits: -amount.milliunits, kind: .reallocationOut
        ))
        context.insert(DurableGoalLedgerEntry(
            goalId: target.id, date: .now,
            amountMilliunits: amount.milliunits, kind: .reallocationIn
        ))
        try save(source: "goals.move")
    }

    /// Record spending from a goal against a posted transaction. Validated
    /// against the transaction's remaining adjustable amount AND the goal's
    /// balance.
    func recordPurchase(
        goal: DurableGoal,
        row: CachedFinancialTransaction,
        amount: Money,
        pipelineContext: SpendingEntryPipeline.Context
    ) throws {
        try validateGoalActive(goal)
        let entries = try allEntries()
        let ceiling = SpendingEntryPipeline.remainingAdjustableAmount(
            row: row,
            existingLedgerEntries: entries,
            context: pipelineContext
        )
        guard amount.milliunits > 0, amount <= ceiling else {
            throw Failure.exceedsAdjustableAmount(ceiling)
        }
        try validateDrawdown(goal: goal, magnitude: amount, entries: entries)
        context.insert(DurableGoalLedgerEntry(
            goalId: goal.id,
            date: row.postedDate,
            amountMilliunits: -amount.milliunits,
            kind: .purchase,
            linkedTransactionExternalId: row.externalId
        ))
        try save(source: "goals.purchase")
    }

    /// Delete or shrink a ledger entry. The resulting goal balance must stay
    /// nonnegative — removing an old contribution under a later purchase is
    /// blocked, not absorbed.
    func deleteEntry(_ entry: DurableGoalLedgerEntry) throws {
        let entries = try allEntries()
        let goalId = entry.goalId
        let resulting = balance(of: goalId, entries: entries).milliunits
            - entry.amountMilliunits
        guard resulting >= 0 else {
            throw Failure.balanceWouldGoNegative(
                Money(milliunits: resulting)
            )
        }
        if entry.amountMilliunits > 0 {
            // Removing an allocation frees pool capacity — always safe.
        }
        context.delete(entry)
        try save(source: "goals.deleteEntry")
    }

    func updateEntry(
        _ entry: DurableGoalLedgerEntry,
        amount: Money,
        date: Date,
        note: String?
    ) throws {
        let entries = try allEntries()
        let resulting = balance(of: entry.goalId, entries: entries).milliunits
            - entry.amountMilliunits + amount.milliunits
        guard resulting >= 0 else {
            throw Failure.balanceWouldGoNegative(Money(milliunits: resulting))
        }
        let growth = amount.milliunits - entry.amountMilliunits
        if growth > 0 {
            try validateAllocation(Money(milliunits: growth))
        }
        entry.amountMilliunits = amount.milliunits
        entry.date = date
        entry.note = note
        entry.updatedAt = .now
        try save(source: "goals.updateEntry")
    }

    // MARK: - Reserve accounts and suggestions

    func addReserveAccount(_ account: CachedFinancialAccount) throws {
        try addReserveAccount(
            canonicalAccountId: account.canonicalAccountId,
            accountName: account.name,
            institutionName: account.institutionName ?? "",
            mask: account.mask ?? ""
        )
    }

    /// Source-neutral add: `canonicalAccountId` is the source-neutral cash
    /// id for cash accounts, or the Plaid account id for a taxable brokerage.
    func addReserveAccount(
        canonicalAccountId: String,
        accountName: String,
        institutionName: String,
        mask: String
    ) throws {
        let existing = try context.fetch(
            FetchDescriptor<DurableGoalReserveAccount>()
        )
        if let row = existing.first(
            where: { $0.canonicalAccountId == canonicalAccountId }
        ) {
            row.active = true
            row.accountName = accountName
            row.institutionName = institutionName
            row.mask = mask
            row.updatedAt = .now
        } else {
            context.insert(DurableGoalReserveAccount(
                canonicalAccountId: canonicalAccountId,
                accountName: accountName,
                institutionName: institutionName,
                mask: mask
            ))
        }
        try save(source: "goals.reserveAdd")
    }

    func removeReserveAccount(_ reserve: DurableGoalReserveAccount) throws {
        reserve.active = false
        reserve.updatedAt = .now
        try save(source: "goals.reserveRemove")
    }

    /// User-confirmed re-attach after a Plaid re-link minted a new canonical
    /// id. Never automatic — institution+mask is a suggestion key only.
    func reattachReserveAccount(
        _ reserve: DurableGoalReserveAccount,
        to account: CachedFinancialAccount
    ) throws {
        reserve.canonicalAccountId = account.canonicalAccountId
        reserve.accountName = account.name
        reserve.institutionName = account.institutionName ?? ""
        reserve.mask = account.mask ?? ""
        reserve.updatedAt = .now
        try save(source: "goals.reserveReattach")
    }

    // MARK: - Validation

    private func validateGoalActive(_ goal: DurableGoal) throws {
        guard goal.toCore().isActive else { throw Failure.goalInactive }
    }

    private func validateAllocation(_ amount: Money) throws {
        let summary = try poolSummary()
        guard summary.shortfall.isZero else { throw Failure.poolInShortfall }
        guard ReservePoolMath.canAllocate(amount, in: summary) else {
            throw Failure.exceedsUnallocated(summary.unallocated)
        }
    }

    private func validateDrawdown(
        goal: DurableGoal,
        magnitude: Money,
        entries: [DurableGoalLedgerEntry]? = nil
    ) throws {
        let current = balance(
            of: goal.id, entries: try entries ?? allEntries()
        )
        guard magnitude <= current else {
            throw Failure.balanceWouldGoNegative(current - magnitude)
        }
    }

    private func save(source: String) throws {
        guard context.safeSave(source: source) else {
            context.rollback()
            throw Failure.saveFailed
        }
    }
}
