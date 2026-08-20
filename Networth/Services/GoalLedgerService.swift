import Foundation
import SwiftData
import NetworthCore

/// Goal-backed Plaid investments respect explicit duplicate/exclude decisions.
/// A missing or pending treatment remains eligible because some connected
/// cash accounts have no editable investment-reconciliation control.
enum GoalReserveAccountEligibility {
    private static let manualAssetPrefix = "manual-asset:"

    static func canBackGoals(_ account: CachedFinancialAccount) -> Bool {
        switch account.type {
        case .checking, .savings, .cash:
            true
        case .investment:
            !PlaidRetirementClassifier.isRetirement(
                subtype: account.subtype
            )
        case .creditCard, .loan:
            false
        case .other:
            (account.currentBalanceMilliunits ?? 0) >= 0
        }
    }

    static func eligiblePlaidAccounts(
        _ accounts: [CachedPlaidAccount],
        treatments: [DurablePlaidAccountTreatment]
    ) -> [CachedPlaidAccount] {
        let treatmentById = Dictionary(
            treatments.map { ($0.plaidAccountId, $0.treatment) },
            uniquingKeysWith: { _, latest in latest }
        )
        return accounts.filter { account in
            guard !PlaidRetirementClassifier.isRetirement(
                subtype: account.subtype
            ) else { return false }
            return switch treatmentById[account.id] {
            case .duplicateManualAsset, .excluded:
                false
            case .duplicateYNAB, .pendingReview, .included, nil:
                true
            }
        }
    }

    static func canBackGoals(_ asset: DurableManualAsset) -> Bool {
        !asset.deleted && asset.kind == .other
    }

    static func reserveID(for asset: DurableManualAsset) -> String {
        manualAssetPrefix + asset.id.uuidString
    }
}

/// Resolves one reserve account's conservative balance from either the
/// source-neutral cash record or the Plaid investments record (taxable
/// brokerage). Shared by the main-actor service and the off-main build actor,
/// so the pool total agrees everywhere. `nil` = account missing/deleted,
/// which the caller treats as zero (surfacing a shortfall).
enum ReserveBalance {
    static func conservative(
        canonicalAccountId: String,
        financialById: [String: CachedFinancialAccount],
        plaidById: [String: CachedPlaidAccount],
        manualValueById: [String: Money] = [:]
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
        if let manualValue = manualValueById[canonicalAccountId] {
            return max(manualValue, .zero)
        }
        return nil
    }
}

@MainActor
struct GoalTransferRequestService {
    let context: ModelContext

    @discardableResult
    func synchronize(for transaction: CachedFinancialTransaction) throws
        -> Bool {
        let reserves = try context.fetch(
            FetchDescriptor<DurableGoalReserveAccount>()
        ).filter(\.active)
        let reserveIds = Set(reserves.map(\.canonicalAccountId))
        let accountName = try context.fetch(
            FetchDescriptor<CachedFinancialAccount>()
        ).first { $0.canonicalAccountId == transaction.canonicalAccountId }?.name
            ?? transaction.canonicalAccountId
        let transactionAccount = try context.fetch(
            FetchDescriptor<CachedFinancialAccount>()
        ).first { $0.canonicalAccountId == transaction.canonicalAccountId }
        let knownCashflowId = transactionAccount?.type.isCashLike == true
            ? transaction.canonicalAccountId : ""
        let existing = try context.fetch(
            FetchDescriptor<DurableGoalTransferRequest>()
        ).filter { $0.transactionId == transaction.id }

        struct Desired {
            let key: String
            let goalId: UUID
            let direction: GoalTransferDirection
            let amount: Int64
        }
        var desired: [Desired] = []
        if !reserveIds.contains(transaction.canonicalAccountId) {
            let legs = transaction.subtransactions.filter { !$0.deleted }
            if !legs.isEmpty {
                desired = legs.compactMap { leg in
                    guard let goalId = leg.goalId,
                          let type = leg.forecastTreatment else { return nil }
                    let direction: GoalTransferDirection
                    switch type {
                    case .goalSpend: direction = .fundSpend
                    case .goalRefund: direction = .returnRefund
                    default: return nil
                    }
                    return Desired(
                        key: "\(transaction.id)|\(leg.id)",
                        goalId: goalId,
                        direction: direction,
                        amount: Swift.abs(leg.amount.milliunits)
                    )
                }
            } else if let goalId = transaction.goalId {
                let direction: GoalTransferDirection?
                switch transaction.forecastTreatment {
                case .goalSpend: direction = .fundSpend
                case .goalRefund: direction = .returnRefund
                default: direction = nil
                }
                if let direction {
                    desired = [Desired(
                        key: transaction.id,
                        goalId: goalId,
                        direction: direction,
                        amount: Swift.abs(transaction.amountMilliunits)
                    )]
                }
            }
        }

        let desiredKeys = Set(desired.map(\.key))
        var changed = false
        for request in existing where request.active
            && !desiredKeys.contains(request.attributionKey) {
            request.active = false
            request.updatedAt = .now
            changed = true
        }
        for item in desired {
            if let request = existing.first(where: {
                $0.attributionKey == item.key
            }) {
                if !request.active {
                    request.active = true
                    request.completedAt = nil
                    request.matchedTransactionId = nil
                    changed = true
                }
                if request.goalId != item.goalId
                    || request.direction != item.direction
                    || request.amountMilliunits != item.amount
                    || request.transactionAccountId
                        != transaction.canonicalAccountId {
                    request.goalId = item.goalId
                    request.direction = item.direction
                    request.amountMilliunits = item.amount
                    request.transactionAccountId = transaction.canonicalAccountId
                    request.transactionAccountName = accountName
                    request.cashflowAccountId = knownCashflowId
                    request.cashflowAccountName = knownCashflowId.isEmpty
                        ? "" : accountName
                    request.goalAccountId = nil
                    request.goalAccountName = nil
                    request.completedAt = nil
                    request.matchedTransactionId = nil
                    request.updatedAt = .now
                    changed = true
                }
            } else {
                context.insert(DurableGoalTransferRequest(
                    attributionKey: item.key,
                    transactionId: transaction.id,
                    transactionExternalId: transaction.externalId,
                    transactionDate: transaction.postedDate,
                    goalId: item.goalId,
                    direction: item.direction,
                    amountMilliunits: item.amount,
                    transactionAccountId: transaction.canonicalAccountId,
                    transactionAccountName: accountName,
                    cashflowAccountId: knownCashflowId,
                    cashflowAccountName: knownCashflowId.isEmpty
                        ? "" : accountName
                ))
                changed = true
            }
        }
        return changed
    }
}

/// One balance calculation for every Goals surface and write validation.
/// Legacy transaction-linked ledger rows are ignored once the transaction
/// carries direct Goal Spend / Goal Refund attribution, preventing a prior
/// assignment from being counted twice.
enum GoalBalanceCalculator {
    static func rawBalances(
        goals: [DurableGoal],
        ledgerEntries: [DurableGoalLedgerEntry],
        transactions: [CachedFinancialTransaction]
    ) -> [UUID: Money] {
        let goalIDs = Set(goals.map(\.id))
        var directDelta: [UUID: Int64] = [:]
        var directAttributionKeys = Set<String>()
        func attributionKey(_ externalId: String, _ goalId: UUID) -> String {
            "\(externalId)|\(goalId.uuidString)"
        }
        for transaction in transactions
        where !transaction.deleted && !transaction.pending
            && !transaction.requiresReview
            && !transaction.subtransactionsDecodeFailed {
            let legs = transaction.subtransactions.filter { !$0.deleted }
            if !legs.isEmpty {
                for leg in legs {
                    guard let goalId = leg.goalId,
                          goalIDs.contains(goalId),
                          (leg.forecastTreatment == .goalSpend
                            || leg.forecastTreatment == .goalRefund) else {
                        continue
                    }
                    directDelta[goalId, default: 0] += leg.amount.milliunits
                    directAttributionKeys.insert(attributionKey(
                        transaction.externalId,
                        goalId
                    ))
                }
            } else if let goalId = transaction.goalId,
                      goalIDs.contains(goalId),
                      (transaction.forecastTreatment == .goalSpend
                        || transaction.forecastTreatment == .goalRefund) {
                directDelta[goalId, default: 0] +=
                    transaction.amountMilliunits
                directAttributionKeys.insert(attributionKey(
                    transaction.externalId,
                    goalId
                ))
            }
        }

        var totals = directDelta
        for entry in ledgerEntries where goalIDs.contains(entry.goalId) {
            if let externalId = entry.linkedTransactionExternalId,
               directAttributionKeys.contains(attributionKey(
                externalId,
                entry.goalId
               )) {
                continue
            }
            totals[entry.goalId, default: 0] += entry.amountMilliunits
        }
        return Dictionary(uniqueKeysWithValues: goals.map {
            ($0.id, Money(milliunits: totals[$0.id] ?? 0))
        })
    }

    static func effectiveBalances(
        goals: [DurableGoal],
        ledgerEntries: [DurableGoalLedgerEntry],
        transactions: [CachedFinancialTransaction],
        reserveBalance: Money
    ) -> [UUID: Money] {
        let raw = rawBalances(
            goals: goals,
            ledgerEntries: ledgerEntries,
            transactions: transactions
        )
        let active = goals
            .filter { !$0.archived && $0.completedAt == nil }
            .sorted { $0.createdAt < $1.createdAt }
        let residual = active.first(where: \.isResidual)?.id
        let resolved = ReservePoolMath.effectiveBalances(
            reserveBalance: reserveBalance,
            activeGoalIds: active.map { $0.id.uuidString },
            residualGoalId: residual?.uuidString,
            rawBalances: Dictionary(uniqueKeysWithValues: raw.map {
                ($0.key.uuidString, $0.value)
            })
        )
        var result = raw
        for goal in active {
            result[goal.id] = resolved[goal.id.uuidString] ?? .zero
        }
        return result
    }
}

/// The single write path for goals, goal ledger entries, and reserve-account
/// selection. Every mutation re-fetches current state, validates the money
/// invariants, then saves or rolls back — no sheet validates independently.
///
/// Invariants owned here:
/// - Goal balances never go negative — including via deletes and edits.
/// - Staged explicit allocations never exceed the live account pool.
/// - At most one active goal receives the derived remainder.
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
        case remainderNeedsDisposition(Money)
        case transferTargetInactive
        case accountCannotBackGoals

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
            case .remainderNeedsDisposition(let balance):
                "This goal still holds \(CurrencyFormatter.currency(balance)). Release it or move it to another goal first."
            case .transferTargetInactive:
                "The receiving goal is archived or completed."
            case .accountCannotBackGoals:
                "Only asset accounts can back goals."
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

    private func allTransactions() throws -> [CachedFinancialTransaction] {
        try context.fetch(FetchDescriptor<CachedFinancialTransaction>())
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
                .filter(GoalReserveAccountEligibility.canBackGoals)
                .map { ($0.canonicalAccountId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let plaidById = Dictionary(
            try eligiblePlaidReserveAccounts()
                .map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let plaidAccounts = try context.fetch(
            FetchDescriptor<CachedPlaidAccount>()
        )
        let plaidTreatments = try context.fetch(
            FetchDescriptor<DurablePlaidAccountTreatment>()
        )
        let manualAssets = try context.fetch(
            FetchDescriptor<DurableManualAsset>()
        )
        let manualResolver = PlaidContributionResolver(
            plaidAccounts: plaidAccounts,
            treatments: plaidTreatments,
            manualAssets: manualAssets
        )
        let manualValueById = Dictionary(
            uniqueKeysWithValues: manualAssets
                .filter(GoalReserveAccountEligibility.canBackGoals)
                .map {
                    (
                        GoalReserveAccountEligibility.reserveID(for: $0),
                        manualResolver.effectiveValue(for: $0)
                    )
                }
        )
        let liveTotal = reserves.reduce(Int64(0)) { sum, reserve in
            sum + (ReserveBalance.conservative(
                canonicalAccountId: reserve.canonicalAccountId,
                financialById: financialById,
                plaidById: plaidById,
                manualValueById: manualValueById
            )?.milliunits ?? 0)
        }
        let pendingAdjustment = try context.fetch(
            FetchDescriptor<DurableGoalTransferRequest>()
        ).filter {
            $0.active && $0.completedAt == nil
        }.map(\.pendingPoolAdjustment).sum().milliunits
        return Money(milliunits: max(0, liveTotal + pendingAdjustment))
    }

    private func eligiblePlaidReserveAccounts() throws
        -> [CachedPlaidAccount] {
        GoalReserveAccountEligibility.eligiblePlaidAccounts(
            try context.fetch(FetchDescriptor<CachedPlaidAccount>()),
            treatments: try context.fetch(
                FetchDescriptor<DurablePlaidAccountTreatment>()
            )
        )
    }

    func poolSummary() throws -> ReservePoolSummary {
        let goals = try allGoals()
        let entries = try allEntries()
        let reserve = try reservePoolBalance()
        let balances = GoalBalanceCalculator.effectiveBalances(
            goals: goals,
            ledgerEntries: entries,
            transactions: try allTransactions(),
            reserveBalance: reserve
        )
        let activeBalances = goals
            .filter { $0.toCore().isActive }
            .map { balances[$0.id] ?? .zero }
        return ReservePoolMath.summary(
            reserveBalance: reserve,
            activeGoalBalances: activeBalances
        )
    }

    /// Commits the entire allocation screen in one save. Every active,
    /// non-residual goal receives an explicit target balance; one optional
    /// residual goal derives all remaining value from the live account pool.
    func applyAllocations(
        _ allocations: [UUID: Money],
        residualGoalId: UUID?
    ) throws {
        let goals = try allGoals()
        let active = goals.filter { $0.toCore().isActive }
        if let residualGoalId,
           !active.contains(where: { $0.id == residualGoalId }) {
            throw Failure.goalInactive
        }
        let explicit = active.filter { $0.id != residualGoalId }
        let targets = Dictionary(uniqueKeysWithValues: explicit.map { goal in
            (goal.id, allocations[goal.id] ?? .zero)
        })
        guard targets.values.allSatisfy({ $0.milliunits >= 0 }) else {
            throw Failure.balanceWouldGoNegative(.zero)
        }
        let reserve = try reservePoolBalance()
        let explicitTotal = targets.values.map(\.milliunits).reduce(0, +)
        guard explicitTotal <= reserve.milliunits else {
            throw Failure.exceedsUnallocated(
                Money(milliunits: max(0, reserve.milliunits))
            )
        }

        let entries = try allEntries()
        let raw = GoalBalanceCalculator.rawBalances(
            goals: goals,
            ledgerEntries: entries,
            transactions: try allTransactions()
        )
        for goal in explicit {
            let delta = (targets[goal.id] ?? .zero)
                - (raw[goal.id] ?? .zero)
            guard !delta.isZero else { continue }
            context.insert(DurableGoalLedgerEntry(
                goalId: goal.id,
                date: .now,
                amountMilliunits: delta.milliunits,
                kind: .manual
            ))
        }
        for goal in goals {
            goal.isResidual = goal.id == residualGoalId
                && goal.toCore().isActive
            goal.updatedAt = .now
        }
        try save(source: "goals.applyAllocations")
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
        let goals = try allGoals()
        let reserve = try reservePoolBalance()
        let current = GoalBalanceCalculator.effectiveBalances(
            goals: goals,
            ledgerEntries: entries,
            transactions: try allTransactions(),
            reserveBalance: reserve
        )[goal.id] ?? .zero
        if current.milliunits > 0 {
            switch remainder {
            case nil:
                throw Failure.remainderNeedsDisposition(current)
            case .release:
                if !goal.isResidual {
                    context.insert(DurableGoalLedgerEntry(
                        goalId: goal.id,
                        date: .now,
                        amountMilliunits: -current.milliunits,
                        kind: .withdrawal,
                        note: "Released on archive"
                    ))
                }
            case .transfer(let target):
                guard target.toCore().isActive, target.id != goal.id else {
                    throw Failure.transferTargetInactive
                }
                // A residual balance is derived rather than stored, so only
                // the receiving allocation is written when closing it.
                if !goal.isResidual {
                    context.insert(DurableGoalLedgerEntry(
                        goalId: goal.id,
                        date: .now,
                        amountMilliunits: -current.milliunits,
                        kind: .reallocationOut
                    ))
                }
                if !target.isResidual {
                    context.insert(DurableGoalLedgerEntry(
                        goalId: target.id,
                        date: .now,
                        amountMilliunits: current.milliunits,
                        kind: .reallocationIn
                    ))
                }
            }
        }
        goal.isResidual = false
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
        guard GoalReserveAccountEligibility.canBackGoals(account) else {
            throw Failure.accountCannotBackGoals
        }
        try addReserveAccount(
            canonicalAccountId: account.canonicalAccountId,
            accountName: account.name,
            institutionName: account.institutionName ?? "",
            mask: account.mask ?? ""
        )
    }

    func addReserveAccount(_ asset: DurableManualAsset) throws {
        guard GoalReserveAccountEligibility.canBackGoals(asset) else {
            throw Failure.accountCannotBackGoals
        }
        try addReserveAccount(
            canonicalAccountId:
                GoalReserveAccountEligibility.reserveID(for: asset),
            accountName: asset.name,
            institutionName: "Manual",
            mask: ""
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
        let goals = try allGoals()
        let current = GoalBalanceCalculator.effectiveBalances(
            goals: goals,
            ledgerEntries: try entries ?? allEntries(),
            transactions: try allTransactions(),
            reserveBalance: try reservePoolBalance()
        )[goal.id] ?? .zero
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
