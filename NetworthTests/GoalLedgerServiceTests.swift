import Foundation
import Testing
import SwiftData
@testable import Networth
import NetworthCore

/// App-level coverage for the Goals money invariants: the schema registers,
/// The schema owns the new types, the shared pipeline resolves external ids,
/// and `GoalLedgerService` enforces every mutation rule.
@MainActor
@Suite("Goal ledger service and pipeline")
struct GoalLedgerServiceTests {

    private func makeContext() throws -> ModelContext {
        try ModelContainerFactory.makeContainer(inMemory: true).mainContext
    }

    // MARK: - Fixtures

    private func insertSavingsAccount(
        _ context: ModelContext,
        canonicalId: String = "acct-savings",
        balance: Int64
    ) -> CachedFinancialAccount {
        let account = CachedFinancialAccount(
            canonicalAccountId: canonicalId,
            externalId: "ext-\(canonicalId)",
            itemId: nil,
            source: .plaid,
            institutionName: "Test Bank",
            name: "Savings",
            officialName: nil,
            mask: "1234",
            type: .savings,
            subtype: nil,
            currentBalanceMilliunits: balance,
            availableBalanceMilliunits: balance,
            creditLimitMilliunits: nil,
            isoCurrencyCode: "USD"
        )
        context.insert(account)
        return account
    }

    private func insertTransaction(
        _ context: ModelContext,
        id: String,
        externalId: String,
        accountId: String = "acct-checking",
        amountMilliunits: Int64,
        treatment: ForecastTreatment = .ordinarySpending,
        legs: [SubTransactionSummary] = []
    ) -> CachedFinancialTransaction {
        let summary = FinancialTransactionSummary(
            id: id,
            externalId: externalId,
            source: .plaid,
            accountId: accountId,
            postedDate: Date(timeIntervalSince1970: 1_754_000_000),
            authorizedDate: nil,
            amount: Money(milliunits: amountMilliunits),
            pending: false,
            pendingTransactionId: nil,
            rawDescription: "Test transaction",
            originalDescription: nil,
            providerMerchantName: "Test Merchant",
            merchantEntityId: nil,
            counterpartyName: nil,
            counterpartyType: nil,
            counterpartyEntityId: nil,
            counterpartyConfidence: nil,
            paymentChannel: nil,
            providerCategoryPrimary: nil,
            providerCategoryDetailed: nil,
            providerCategoryConfidence: nil,
            transactionCode: nil
        )
        let classification = TransactionClassification(
            displayName: "Test Merchant",
            category: .other,
            treatment: treatment,
            confidence: .high,
            provenance: .user,
            requiresReview: false
        )
        let row = CachedFinancialTransaction(
            summary: summary,
            classification: classification,
            subtransactionsData: legs.isEmpty
                ? nil : try? JSONEncoder().encode(legs)
        )
        context.insert(row)
        return row
    }

    // MARK: - Schema membership

    @Test func goalModelsRegisterAndPersistInBothSchemas() throws {
        let context = try makeContext()
        let goal = DurableGoal(name: "House", kind: .oneTime)
        context.insert(goal)
        context.insert(DurableGoalLedgerEntry(
            goalId: goal.id, amountMilliunits: 5_000, kind: .manual
        ))
        context.insert(DurableGoalReserveAccount(
            canonicalAccountId: "acct-1", accountName: "Savings"
        ))
        try context.save()
        #expect(try context.fetchCount(
            FetchDescriptor<DurableGoal>()
        ) == 1)
        #expect(try context.fetchCount(
            FetchDescriptor<DurableGoalLedgerEntry>()
        ) == 1)
        #expect(try context.fetchCount(
            FetchDescriptor<DurableGoalReserveAccount>()
        ) == 1)
    }

    // MARK: - Investment-backed reserve

    @Test func taxableBrokerageContributesToReservePool() throws {
        let context = try makeContext()
        _ = insertSavingsAccount(context, balance: 500_000)
        // A taxable brokerage lives only on the Plaid investments path.
        context.insert(CachedPlaidAccount(
            id: "plaid-brokerage-1",
            itemId: "item-1",
            institutionName: "Fidelity",
            name: "Brokerage",
            mask: "5609",
            typeRaw: "investment",
            subtype: "brokerage",
            currentBalanceMilliunits: 100_000_000,
            isoCurrencyCode: "USD"
        ))
        try context.save()
        let service = GoalLedgerService(context: context)

        // Add both a cash account and the brokerage as reserves.
        let cash = try #require(context.fetch(
            FetchDescriptor<CachedFinancialAccount>()
        ).first)
        try service.addReserveAccount(cash)
        try service.addReserveAccount(
            canonicalAccountId: "plaid-brokerage-1",
            accountName: "Brokerage",
            institutionName: "Fidelity",
            mask: "5609"
        )

        // Pool = savings $500 + brokerage market value $100,000.
        #expect(try service.reservePoolBalance()
            == Money(milliunits: 100_500_000))

        // Allocation can draw against the brokerage-backed pool.
        let goal = try service.createGoal(name: "House", kind: .oneTime)
        try service.addManualEntry(
            goal: goal, amount: Money(milliunits: 50_000_000),
            date: .now, note: nil
        )
        #expect(try service.poolSummary().unallocated
            == Money(milliunits: 50_500_000))
    }

    // MARK: - Allocation invariants

    @Test func stagedAllocationsCommitTogetherAndResidualTracksPool() async throws {
        let container = try ModelContainerFactory.makeContainer(inMemory: true)
        let context = container.mainContext
        let account = insertSavingsAccount(context, balance: 1_000_000)
        let service = GoalLedgerService(context: context)
        try service.addReserveAccount(account)
        let travel = try service.createGoal(
            name: "Travel", kind: .refillable
        )
        let investments = try service.createGoal(
            name: "Investments", kind: .refillable
        )

        try service.applyAllocations(
            [travel.id: Money(milliunits: 300_000)],
            residualGoalId: investments.id
        )

        var model = try await GoalsBuildActor(
            modelContainer: container
        ).build(now: .now)
        #expect(model.activeGoals.first {
            $0.goalUUID == travel.id
        }?.balance == Money(milliunits: 300_000))
        #expect(model.activeGoals.first {
            $0.goalUUID == investments.id
        }?.balance == Money(milliunits: 700_000))
        #expect(investments.isResidual)
        #expect(!travel.isResidual)

        account.currentBalanceMilliunits = 1_250_000
        account.availableBalanceMilliunits = 1_250_000
        try context.save()
        model = try await GoalsBuildActor(
            modelContainer: container
        ).build(now: .now)
        #expect(model.activeGoals.first {
            $0.goalUUID == investments.id
        }?.balance == Money(milliunits: 950_000))
    }

    @Test func allocationsRespectUnallocatedPool() throws {
        let context = try makeContext()
        _ = insertSavingsAccount(context, balance: 500_000)
        let service = GoalLedgerService(context: context)
        let goal = try service.createGoal(name: "Travel", kind: .refillable)
        let account = try #require(context.fetch(
            FetchDescriptor<CachedFinancialAccount>()
        ).first)
        try service.addReserveAccount(account)

        try service.addManualEntry(
            goal: goal, amount: Money(milliunits: 400_000),
            date: .now, note: nil
        )
        // Only $100 of the $500 pool remains unallocated.
        #expect(throws: GoalLedgerService.Failure.self) {
            try service.addManualEntry(
                goal: goal, amount: Money(milliunits: 200_000),
                date: .now, note: nil
            )
        }
    }

    @Test func releaseReturnsMoneyToUnallocated() throws {
        let context = try makeContext()
        _ = insertSavingsAccount(context, balance: 500_000)
        let service = GoalLedgerService(context: context)
        let goal = try service.createGoal(name: "Travel", kind: .refillable)
        let account = try #require(context.fetch(
            FetchDescriptor<CachedFinancialAccount>()
        ).first)
        try service.addReserveAccount(account)
        try service.addManualEntry(
            goal: goal, amount: Money(milliunits: 300_000),
            date: .now, note: nil
        )
        // Withdraw = negative manual entry, capped at the goal balance.
        #expect(throws: GoalLedgerService.Failure.self) {
            try service.addManualEntry(
                goal: goal, amount: Money(milliunits: -400_000),
                date: .now, note: nil
            )
        }
        try service.addManualEntry(
            goal: goal, amount: Money(milliunits: -100_000),
            date: .now, note: nil
        )
        #expect(try service.poolSummary().unallocated
            == Money(milliunits: 300_000))
    }

    @Test func moveBetweenGoalsIsNetZeroAndCapped() throws {
        let context = try makeContext()
        _ = insertSavingsAccount(context, balance: 1_000_000)
        let service = GoalLedgerService(context: context)
        let source = try service.createGoal(name: "Travel", kind: .refillable)
        let target = try service.createGoal(name: "House", kind: .oneTime)
        let account = try #require(context.fetch(
            FetchDescriptor<CachedFinancialAccount>()
        ).first)
        try service.addReserveAccount(account)
        try service.addManualEntry(
            goal: source, amount: Money(milliunits: 300_000),
            date: .now, note: nil
        )
        // Can't move more than the source holds.
        #expect(throws: GoalLedgerService.Failure.self) {
            try service.moveBetweenGoals(
                from: source, to: target, amount: Money(milliunits: 400_000)
            )
        }
        try service.moveBetweenGoals(
            from: source, to: target, amount: Money(milliunits: 200_000)
        )
        let summary = try service.poolSummary()
        // Pool allocation unchanged by an internal move.
        #expect(summary.allocated == Money(milliunits: 300_000))
    }

    // MARK: - Archive lifecycle

    @Test func archiveWithBalanceRequiresDisposition() throws {
        let context = try makeContext()
        _ = insertSavingsAccount(context, balance: 1_000_000)
        let service = GoalLedgerService(context: context)
        let goal = try service.createGoal(name: "Travel", kind: .refillable)
        let account = try #require(context.fetch(
            FetchDescriptor<CachedFinancialAccount>()
        ).first)
        try service.addReserveAccount(account)
        try service.addManualEntry(
            goal: goal, amount: Money(milliunits: 300_000),
            date: .now, note: nil
        )

        #expect(throws: GoalLedgerService.Failure.self) {
            try service.archiveGoal(goal, remainder: nil)
        }
    }

    @Test func archiveTransferWritesAtomicReallocationPair() throws {
        let context = try makeContext()
        _ = insertSavingsAccount(context, balance: 1_000_000)
        let service = GoalLedgerService(context: context)
        let source = try service.createGoal(name: "Old", kind: .refillable)
        let target = try service.createGoal(name: "New", kind: .refillable)
        let account = try #require(context.fetch(
            FetchDescriptor<CachedFinancialAccount>()
        ).first)
        try service.addReserveAccount(account)
        try service.addManualEntry(
            goal: source, amount: Money(milliunits: 300_000),
            date: .now, note: nil
        )

        try service.archiveGoal(source, remainder: .transfer(to: target))

        let entries = try context.fetch(
            FetchDescriptor<DurableGoalLedgerEntry>()
        )
        let out = entries.first { $0.kind == .reallocationOut }
        let inn = entries.first { $0.kind == .reallocationIn }
        #expect(out?.goalId == source.id)
        #expect(out?.amountMilliunits == -300_000)
        #expect(inn?.goalId == target.id)
        #expect(inn?.amountMilliunits == 300_000)
        #expect(source.archived)
        // Source is empty, target holds the money: pool unchanged.
        let summary = try service.poolSummary()
        #expect(summary.allocated == Money(milliunits: 300_000))
        // Reallocations never count as monthly contributions.
        let targetMTD = GoalMath.monthToDateContributions(
            entries: entries.filter { $0.goalId == target.id }
                .map { $0.toCore() },
            asOf: .now
        )
        #expect(targetMTD.isZero)
    }

    // MARK: - Release on archive returns money to unallocated

    @Test func archiveReleaseFreesAllocation() throws {
        let context = try makeContext()
        _ = insertSavingsAccount(context, balance: 1_000_000)
        let service = GoalLedgerService(context: context)
        let goal = try service.createGoal(name: "Travel", kind: .refillable)
        let account = try #require(context.fetch(
            FetchDescriptor<CachedFinancialAccount>()
        ).first)
        try service.addReserveAccount(account)
        try service.addManualEntry(
            goal: goal, amount: Money(milliunits: 300_000),
            date: .now, note: nil
        )

        try service.archiveGoal(goal, remainder: .release)

        let summary = try service.poolSummary()
        #expect(summary.allocated.isZero)
        #expect(summary.unallocated == Money(milliunits: 1_000_000))
    }

    // MARK: - Pipeline external-id resolution

    @Test func goalBalanceDerivesSpendAndRefundFromTransactionTypes() async throws {
        let container = try ModelContainerFactory.makeContainer(inMemory: true)
        let context = container.mainContext
        let service = GoalLedgerService(context: context)
        let goal = try service.createGoal(name: "Travel", kind: .refillable)
        try service.addManualEntry(
            goal: goal,
            amount: Money(milliunits: 10_000_000),
            date: .now,
            note: nil
        )
        let spend = insertTransaction(
            context,
            id: "goal-spend",
            externalId: "goal-spend",
            amountMilliunits: -3_000_000,
            treatment: .goalSpend
        )
        spend.goalId = goal.id
        let refund = insertTransaction(
            context,
            id: "goal-refund",
            externalId: "goal-refund",
            amountMilliunits: 1_000_000,
            treatment: .goalRefund
        )
        refund.goalId = goal.id
        try context.save()

        let model = try await GoalsBuildActor(
            modelContainer: container
        ).build(now: .now)
        let item = try #require(model.activeGoals.first {
            $0.goalUUID == goal.id
        })
        #expect(item.balance == Money(milliunits: 8_000_000))
    }

    // MARK: - Derived projection exclusion

    @Test func projectionPoolExcludesActiveReservesAndRestores() {
        let checking = AccountSnapshot(
            id: "acct-checking", name: "Checking", kind: .checking,
            balance: .dollars(integer: 1_000),
            clearedBalance: .dollars(integer: 1_000),
            unclearedBalance: .zero,
            onBudget: true, closed: false, deleted: false
        )
        let savings = AccountSnapshot(
            id: "acct-savings", name: "Savings", kind: .savings,
            balance: .dollars(integer: 5_000),
            clearedBalance: .dollars(integer: 5_000),
            unclearedBalance: .zero,
            onBudget: true, closed: false, deleted: false
        )

        // Backing goals: the savings account leaves the pool even though the
        // user's setting (onBudget default) would include it.
        let whileReserved = ProjectionCashSelection.selectedAccounts(
            openCash: [checking, savings],
            overrideMap: [:],
            goalReserveIds: ["acct-savings"]
        )
        #expect(whileReserved.map(\.id) == ["acct-checking"])

        // Reserve removed: the prior setting still stands and the account
        // returns — nothing was overwritten.
        let afterRemoval = ProjectionCashSelection.selectedAccounts(
            openCash: [checking, savings],
            overrideMap: [:],
            goalReserveIds: []
        )
        #expect(afterRemoval.map(\.id) == [
            "acct-checking", "acct-savings"
        ])

        // A stored user exclusion is respected independently of goals.
        let withUserExclusion = ProjectionCashSelection.selectedAccounts(
            openCash: [checking, savings],
            overrideMap: ["acct-savings": false],
            goalReserveIds: []
        )
        #expect(withUserExclusion.map(\.id) == ["acct-checking"])
    }
}
