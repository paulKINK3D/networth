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
        context.insert(DurableGoalTransferRequest(
            attributionKey: "transaction-1",
            transactionId: "transaction-1",
            goalId: goal.id,
            amountMilliunits: 5_000
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
        #expect(try context.fetchCount(
            FetchDescriptor<DurableGoalTransferRequest>()
        ) == 1)
    }

    // MARK: - Investment-backed reserve

    @Test func taxableBrokerageContributesToReservePool() throws {
        let context = try makeContext()
        _ = insertSavingsAccount(context, balance: 500_000)
        // A taxable brokerage lives only on the Plaid investments path.
        let brokerage = CachedPlaidAccount(
            id: "plaid-brokerage-1",
            itemId: "item-1",
            institutionName: "Fidelity",
            name: "Brokerage",
            mask: "5609",
            typeRaw: "investment",
            subtype: "brokerage",
            currentBalanceMilliunits: 100_000_000,
            isoCurrencyCode: "USD"
        )
        context.insert(brokerage)
        context.insert(DurablePlaidAccountTreatment(
            plaidAccountId: brokerage.id,
            treatment: .included
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

    @Test func manualOtherAccountCanBackGoals() async throws {
        let container = try ModelContainerFactory.makeContainer(inMemory: true)
        let context = container.mainContext
        let asset = DurableManualAsset(
            name: "Manual Savings",
            kind: .other
        )
        let value = DurableManualAssetValue(
            amountMilliunits: 750_000,
            asset: asset
        )
        asset.values = [value]
        context.insert(asset)
        context.insert(value)
        try context.save()

        let service = GoalLedgerService(context: context)
        try service.addReserveAccount(asset)

        #expect(try service.reservePoolBalance()
            == Money(milliunits: 750_000))
        let model = try await GoalsBuildActor(
            modelContainer: container
        ).build(now: .now)
        #expect(model.pool.pool == Money(milliunits: 750_000))
        #expect(model.reserves.first?.canonicalAccountId
            == GoalReserveAccountEligibility.reserveID(for: asset))
        #expect(model.unavailableReserves.isEmpty)
    }

    @Test func nonAccountManualAssetsCannotBackGoals() throws {
        let context = try makeContext()
        let property = DurableManualAsset(
            name: "Home",
            kind: .realEstate
        )
        context.insert(property)
        try context.save()

        #expect(!GoalReserveAccountEligibility.canBackGoals(property))
        #expect(throws: GoalLedgerService.Failure.self) {
            try GoalLedgerService(context: context)
                .addReserveAccount(property)
        }
    }

    @Test func excludedInvestmentIsNotCountedAsAGoalAccount() async throws {
        let container = try ModelContainerFactory.makeContainer(inMemory: true)
        let context = container.mainContext
        let account = CachedPlaidAccount(
            id: "excluded-ira",
            itemId: "item-1",
            institutionName: "Vanguard",
            name: "IRA",
            mask: "0000",
            typeRaw: "investment",
            subtype: "ira",
            currentBalanceMilliunits: 25_000_000,
            isoCurrencyCode: "USD"
        )
        context.insert(account)
        context.insert(DurablePlaidAccountTreatment(
            plaidAccountId: account.id,
            treatment: .excluded
        ))
        context.insert(DurableGoalReserveAccount(
            canonicalAccountId: account.id,
            accountName: account.name,
            institutionName: account.institutionName,
            mask: account.mask ?? ""
        ))
        try context.save()

        let service = GoalLedgerService(context: context)
        #expect(try service.reservePoolBalance() == .zero)

        let model = try await GoalsBuildActor(
            modelContainer: container
        ).build(now: .now)
        #expect(model.pool.pool == .zero)
        #expect(model.unavailableReserves.map(\.canonicalAccountId)
            == [account.id])
    }

    @Test func connectedCashAccountWithoutEditableTreatmentStillCounts() throws {
        let context = try makeContext()
        let account = CachedPlaidAccount(
            id: "cash-plus",
            itemId: "item-1",
            institutionName: "Vanguard",
            name: "Cash Plus",
            mask: "8778",
            typeRaw: "investment",
            subtype: "cash management",
            currentBalanceMilliunits: 136_993_000,
            isoCurrencyCode: "USD"
        )
        context.insert(account)
        context.insert(DurableGoalReserveAccount(
            canonicalAccountId: account.id,
            accountName: account.name,
            institutionName: account.institutionName,
            mask: account.mask ?? ""
        ))
        try context.save()

        #expect(try GoalLedgerService(context: context).reservePoolBalance()
            == Money(milliunits: 136_993_000))
    }

    @Test func debtAccountsCannotBackGoals() throws {
        let context = try makeContext()
        let card = CachedFinancialAccount(
            canonicalAccountId: "credit-card",
            externalId: "credit-card",
            itemId: "item-1",
            source: .plaid,
            institutionName: "Test Bank",
            name: "Credit Card",
            officialName: nil,
            mask: "1234",
            type: .creditCard,
            subtype: nil,
            currentBalanceMilliunits: -1_000_000,
            availableBalanceMilliunits: nil,
            creditLimitMilliunits: 10_000_000,
            isoCurrencyCode: "USD"
        )
        context.insert(card)
        context.insert(DurableGoalReserveAccount(
            canonicalAccountId: card.canonicalAccountId,
            accountName: card.name
        ))
        try context.save()

        let service = GoalLedgerService(context: context)
        #expect(throws: GoalLedgerService.Failure.self) {
            try service.addReserveAccount(card)
        }
        #expect(try service.reservePoolBalance() == .zero)
    }

    @Test func retirementAccountsCannotBackGoals() throws {
        let context = try makeContext()
        let ira = CachedPlaidAccount(
            id: "ira",
            itemId: "item-1",
            institutionName: "Vanguard",
            name: "IRA",
            typeRaw: "investment",
            subtype: "ira",
            currentBalanceMilliunits: 100_000_000,
            isoCurrencyCode: "USD"
        )
        context.insert(ira)
        context.insert(DurablePlaidAccountTreatment(
            plaidAccountId: ira.id,
            treatment: .included
        ))
        context.insert(DurableGoalReserveAccount(
            canonicalAccountId: ira.id,
            accountName: ira.name
        ))
        try context.save()

        #expect(GoalReserveAccountEligibility.eligiblePlaidAccounts(
            [ira],
            treatments: try context.fetch(
                FetchDescriptor<DurablePlaidAccountTreatment>()
            )
        ).isEmpty)
        #expect(try GoalLedgerService(context: context).reservePoolBalance()
            == .zero)
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

    @Test func changingResidualGoalPreservesStagedFinalBalances() async throws {
        let container = try ModelContainerFactory.makeContainer(inMemory: true)
        let context = container.mainContext
        let account = insertSavingsAccount(context, balance: 1_000_000)
        let service = GoalLedgerService(context: context)
        try service.addReserveAccount(account)
        let emergency = try service.createGoal(
            name: "Emergency", kind: .refillable
        )
        let downPayment = try service.createGoal(
            name: "Down Payment", kind: .oneTime
        )
        try service.applyAllocations(
            [emergency.id: Money(milliunits: 300_000)],
            residualGoalId: downPayment.id
        )

        try service.applyAllocations(
            [
                emergency.id: Money(milliunits: 300_000),
                downPayment.id: Money(milliunits: 700_000)
            ],
            residualGoalId: emergency.id
        )

        let model = try await GoalsBuildActor(
            modelContainer: container
        ).build(now: .now)
        #expect(model.activeGoals.first {
            $0.goalUUID == emergency.id
        }?.balance == Money(milliunits: 300_000))
        #expect(model.activeGoals.first {
            $0.goalUUID == downPayment.id
        }?.balance == Money(milliunits: 700_000))
        #expect(emergency.isResidual)
        #expect(!downPayment.isResidual)
    }

    @Test func movingMoneyAgainstResidualAdjustsOnlySelectedGoal() async throws {
        let container = try ModelContainerFactory.makeContainer(inMemory: true)
        let context = container.mainContext
        let account = insertSavingsAccount(context, balance: 1_000_000)
        let service = GoalLedgerService(context: context)
        try service.addReserveAccount(account)
        let emergency = try service.createGoal(
            name: "Emergency", kind: .refillable
        )
        let remainder = try service.createGoal(
            name: "Down Payment", kind: .oneTime
        )
        try service.applyAllocations(
            [emergency.id: Money(milliunits: 300_000)],
            residualGoalId: remainder.id
        )

        try service.moveBetweenGoals(
            from: remainder,
            to: emergency,
            amount: Money(milliunits: 100_000)
        )
        var model = try await GoalsBuildActor(
            modelContainer: container
        ).build(now: .now)
        #expect(model.activeGoals.first {
            $0.goalUUID == emergency.id
        }?.balance == Money(milliunits: 400_000))
        #expect(model.activeGoals.first {
            $0.goalUUID == remainder.id
        }?.balance == Money(milliunits: 600_000))

        try service.moveBetweenGoals(
            from: emergency,
            to: remainder,
            amount: Money(milliunits: 50_000)
        )
        model = try await GoalsBuildActor(
            modelContainer: container
        ).build(now: .now)
        #expect(model.activeGoals.first {
            $0.goalUUID == emergency.id
        }?.balance == Money(milliunits: 350_000))
        #expect(model.activeGoals.first {
            $0.goalUUID == remainder.id
        }?.balance == Money(milliunits: 650_000))
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

    @Test func pendingGoalSpendDoesNotFlowIntoResidualGoal() async throws {
        let container = try ModelContainerFactory.makeContainer(inMemory: true)
        let context = container.mainContext
        let reserve = insertSavingsAccount(
            context,
            canonicalId: "goal-savings",
            balance: 1_000_000
        )
        let service = GoalLedgerService(context: context)
        try service.addReserveAccount(reserve)
        let travel = try service.createGoal(name: "Travel", kind: .refillable)
        let remainder = try service.createGoal(
            name: "Remainder", kind: .refillable
        )
        try service.applyAllocations(
            [travel.id: Money(milliunits: 300_000)],
            residualGoalId: remainder.id
        )
        let spend = insertTransaction(
            context,
            id: "goal-spend-pending-transfer",
            externalId: "goal-spend-pending-transfer",
            accountId: "acct-checking",
            amountMilliunits: -100_000,
            treatment: .goalSpend
        )
        spend.goalId = travel.id
        try context.save()
        try GoalTransferRequestService(context: context).synchronize(for: spend)
        try context.save()

        let model = try await GoalsBuildActor(
            modelContainer: container
        ).build(now: .now)
        #expect(model.activeGoals.first {
            $0.goalUUID == travel.id
        }?.balance == Money(milliunits: 200_000))
        #expect(model.activeGoals.first {
            $0.goalUUID == remainder.id
        }?.balance == Money(milliunits: 700_000))
        #expect(model.pendingTransfers.count == 1)
        #expect(model.pendingTransferAdjustment
            == Money(milliunits: -100_000))
        #expect(try service.reservePoolBalance()
            == Money(milliunits: 900_000))
    }

    @Test func goalRefundCreatesReversePendingAdjustment() throws {
        let context = try makeContext()
        let goal = DurableGoal(name: "Emergency", kind: .refillable)
        context.insert(goal)
        let refund = insertTransaction(
            context,
            id: "goal-refund-pending-transfer",
            externalId: "goal-refund-pending-transfer",
            amountMilliunits: 125_000,
            treatment: .goalRefund
        )
        refund.goalId = goal.id
        try context.save()

        try GoalTransferRequestService(context: context)
            .synchronize(for: refund)
        try context.save()

        let request = try #require(context.fetch(
            FetchDescriptor<DurableGoalTransferRequest>()
        ).first)
        #expect(request.direction == .returnRefund)
        #expect(request.pendingPoolAdjustment == Money(milliunits: 125_000))
    }

    @Test func spendingFromGoalAccountNeedsNoTransferRequest() throws {
        let context = try makeContext()
        let reserve = insertSavingsAccount(
            context,
            canonicalId: "goal-savings",
            balance: 1_000_000
        )
        let goal = DurableGoal(name: "Travel", kind: .refillable)
        context.insert(goal)
        context.insert(DurableGoalReserveAccount(
            canonicalAccountId: reserve.canonicalAccountId,
            accountName: reserve.name
        ))
        let spend = insertTransaction(
            context,
            id: "direct-goal-spend",
            externalId: "direct-goal-spend",
            accountId: reserve.canonicalAccountId,
            amountMilliunits: -75_000,
            treatment: .goalSpend
        )
        spend.goalId = goal.id
        try context.save()

        try GoalTransferRequestService(context: context)
            .synchronize(for: spend)
        try context.save()

        #expect(try context.fetchCount(
            FetchDescriptor<DurableGoalTransferRequest>()
        ) == 0)
    }

    @Test func changingGoalSpendTypeDeactivatesPendingRequest() throws {
        let context = try makeContext()
        let goal = DurableGoal(name: "Travel", kind: .refillable)
        context.insert(goal)
        let spend = insertTransaction(
            context,
            id: "reclassified-goal-spend",
            externalId: "reclassified-goal-spend",
            amountMilliunits: -100_000,
            treatment: .goalSpend
        )
        spend.goalId = goal.id
        try context.save()
        let service = GoalTransferRequestService(context: context)
        try service.synchronize(for: spend)
        try context.save()

        spend.forecastTreatmentRaw = TransactionType.ordinarySpending.rawValue
        spend.goalId = nil
        try service.synchronize(for: spend)
        try context.save()

        let request = try #require(context.fetch(
            FetchDescriptor<DurableGoalTransferRequest>()
        ).first)
        #expect(!request.active)
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
