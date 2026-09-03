import Foundation
import Testing
@testable import Networth
import NetworthCore

@Suite("Spending entry pipeline")
struct SpendingEntryPipelineTests {
    @Test func internalTransfersNeverBecomeSpendingOrSavingsActivity() {
        let accounts = [
            account(id: "checking", type: .checking),
            account(id: "savings", type: .savings)
        ]
        let context = SpendingEntryPipeline.Context(
            groups: [],
            categories: [],
            accounts: accounts
        )
        let rows = [
            transaction(
                id: "checking-transfer",
                accountID: "checking",
                treatment: .internalTransfer
            ),
            transaction(
                id: "savings-transfer",
                accountID: "savings",
                treatment: .internalTransfer
            ),
            transaction(
                id: "ordinary",
                accountID: "checking",
                treatment: .ordinarySpending
            )
        ]

        let entries = SpendingEntryPipeline.assembleEntries(
            rows: rows,
            context: context
        )

        #expect(entries.map(\.transactionId) == ["ordinary"])
        #expect(!entries.contains { $0.reportingRole == .transfer })
    }

    @Test func designatedSavingsBucketUsesOnlySavingsAccountSide() {
        let accounts = [
            account(id: "checking", type: .checking),
            account(id: "savings", type: .savings),
            account(id: "goal-savings", type: .savings)
        ]
        let assignedMonth = BudgetMonth(year: 2026, month: 8)
        let context = SpendingEntryPipeline.Context(
            groups: [],
            categories: [],
            accounts: accounts,
            savingsGroup: ("savings-group", "Savings"),
            savingsTransferMonthByTransactionID: [
                "savings-transfer": assignedMonth
            ],
            excludedSavingsAccountIDs: ["goal-savings"]
        )
        let rows = [
            transaction(
                id: "checking-transfer",
                accountID: "checking",
                treatment: .internalTransfer
            ),
            transaction(
                id: "savings-transfer",
                accountID: "savings",
                treatment: .internalTransfer
            ),
            transaction(
                id: "goal-transfer",
                accountID: "goal-savings",
                treatment: .internalTransfer
            ),
        ]

        let entries = SpendingEntryPipeline.assembleEntries(
            rows: rows,
            context: context
        )

        #expect(entries.map(\.transactionId) == ["savings-transfer"])
        #expect(entries.first?.reportingRole == .transfer)
        #expect(entries.first?.groupIdentity == "savings-group")
        #expect(
            BudgetMonth(containing: entries.first!.date) == assignedMonth
        )
    }

    @Test func investmentContributionsUseOnlyTheCashAccountSide() {
        let context = SpendingEntryPipeline.Context(
            groups: [],
            categories: [],
            accounts: [
                account(id: "checking", type: .checking),
                account(id: "brokerage", type: .investment)
            ]
        )

        let entries = SpendingEntryPipeline.assembleEntries(
            rows: [
                transaction(
                    id: "cash-side",
                    accountID: "checking",
                    treatment: .investmentContribution
                ),
                transaction(
                    id: "investment-side",
                    accountID: "brokerage",
                    treatment: .investmentContribution
                )
            ],
            context: context
        )

        #expect(entries.map(\.transactionId) == ["cash-side"])
        #expect(entries.first?.reportingRole == .investment)
        #expect(
            entries.first?.groupIdentity
                == SpendingGroupSetup.investmentReportingIdentity
        )
    }

    @Test func reimbursementsAndGoalRefundsStayOutsideSpending() {
        let context = SpendingEntryPipeline.Context(
            groups: [],
            categories: [],
            accounts: [account(id: "checking", type: .checking)]
        )
        let entries = SpendingEntryPipeline.assembleEntries(
            rows: [
                transaction(
                    id: "reimbursable-purchase",
                    accountID: "checking",
                    treatment: .reimbursement
                ),
                transaction(
                    id: "reimbursement",
                    accountID: "checking",
                    treatment: .reimbursement
                ),
                transaction(
                    id: "goal-spend",
                    accountID: "checking",
                    treatment: .goalSpend
                ),
                transaction(
                    id: "goal-refund",
                    accountID: "checking",
                    treatment: .goalRefund
                ),
                transaction(
                    id: "ordinary",
                    accountID: "checking",
                    treatment: .ordinarySpending
                )
            ],
            context: context
        )

        #expect(entries.map(\.transactionId) == ["ordinary"])
    }

    @Test func legacySyntheticReimbursementSplitStaysOutsideSpending() throws {
        let context = SpendingEntryPipeline.Context(
            groups: [],
            categories: [],
            accounts: [account(id: "checking", type: .checking)]
        )
        let row = transaction(
            id: "legacy-split",
            accountID: "checking",
            treatment: .unknown
        )
        row.amountMilliunits = 100_000
        row.subtransactionsData = try JSONEncoder().encode([
            SubTransactionSummary(
                id: "income",
                amount: Money(milliunits: 80_000),
                categoryId: nil,
                categoryName: "Income",
                forecastTreatment: .income,
                payeeName: nil,
                memo: nil,
                deleted: false
            ),
            SubTransactionSummary(
                id: "reimbursement",
                amount: Money(milliunits: 20_000),
                categoryId: nil,
                categoryName: "Reimbursement",
                forecastTreatment: .refund,
                payeeName: nil,
                memo: nil,
                deleted: false
            )
        ])

        let entries = SpendingEntryPipeline.assembleEntries(
            rows: [row],
            context: context
        )

        #expect(entries.map(\.treatment) == [.income, .reimbursement])
        let months = SpendingHistoryBuilder.build(
            entries: entries,
            monthsBack: 1,
            now: row.postedDate,
            calendar: Calendar(identifier: .gregorian)
        )
        #expect(months.count == 1)
        #expect(months[0].incomeMilliunits == 80_000)
        #expect(months[0].totalMilliunits == 0)
    }

    @Test func legacyReimbursementExpenseStaysOutsideSpending() {
        let context = SpendingEntryPipeline.Context(
            groups: [],
            categories: [],
            accounts: [account(id: "checking", type: .checking)]
        )
        let row = transaction(
            id: "legacy-expense",
            accountID: "checking",
            treatment: .ordinarySpending
        )
        row.nativeCategoryRaw = "other"
        row.categoryCanonicalId = LegacyReimbursementRepresentation
            .retiredCanonicalCategoryID
        row.categoryName = "Reimbursement - $5K"

        let entries = SpendingEntryPipeline.assembleEntries(
            rows: [row],
            context: context
        )

        #expect(entries.isEmpty)
    }

    @Test func unknownTypesAndUnreadableSplitsFailClosed() {
        let context = SpendingEntryPipeline.Context(
            groups: [],
            categories: [],
            accounts: [account(id: "checking", type: .checking)]
        )
        let unknown = transaction(
            id: "unknown",
            accountID: "checking",
            treatment: .ordinarySpending
        )
        unknown.forecastTreatmentRaw = "future-type"
        let corrupt = transaction(
            id: "corrupt-split",
            accountID: "checking",
            treatment: .ordinarySpending
        )
        corrupt.subtransactionsData = Data([0xFF])

        #expect(unknown.forecastTreatment == .unknown)
        #expect(corrupt.subtransactionsDecodeFailed)
        #expect(SpendingEntryPipeline.assembleEntries(
            rows: [unknown, corrupt],
            context: context
        ).isEmpty)
    }

    @Test func confirmedSinkingFundPurchaseStaysOutsideMonthlySpending() {
        let context = SpendingEntryPipeline.Context(
            groups: [],
            categories: [],
            accounts: [account(id: "checking", type: .checking)],
            sinkingFundByLine: [
                SpendingSinkingFundLineKey(
                    transactionID: "repair",
                    subtransactionID: nil
                ): SpendingSinkingFundAttribution(
                    fundID: "home",
                    fundName: "Home repair"
                )
            ]
        )
        let row = transaction(
            id: "repair",
            accountID: "checking",
            treatment: .ordinarySpending
        )

        let entries = SpendingEntryPipeline.assembleEntries(
            rows: [row],
            context: context
        )
        let months = SpendingHistoryBuilder.build(
            entries: entries,
            monthsBack: 1,
            now: row.postedDate,
            calendar: Calendar.current
        )

        #expect(entries.isEmpty)
        #expect(months.first?.ordinaryTotalMilliunits == 0)
        #expect(months.first?.groups.isEmpty == true)
    }

    @Test func sinkingFundAssignmentMovesOnlyTheConfirmedSplitLine() throws {
        let context = SpendingEntryPipeline.Context(
            groups: [],
            categories: [],
            accounts: [account(id: "checking", type: .checking)],
            sinkingFundByLine: [
                SpendingSinkingFundLineKey(
                    transactionID: "split",
                    subtransactionID: "repair"
                ): SpendingSinkingFundAttribution(
                    fundID: "home",
                    fundName: "Home repair"
                )
            ]
        )
        let row = transaction(
            id: "split",
            accountID: "checking",
            treatment: .ordinarySpending
        )
        row.amountMilliunits = -100_000
        row.subtransactionsData = try JSONEncoder().encode([
            SubTransactionSummary(
                id: "repair",
                amount: Money(milliunits: -60_000),
                categoryId: "repairs",
                categoryName: "Repairs",
                forecastTreatment: .ordinarySpending,
                payeeName: nil,
                memo: nil,
                deleted: false
            ),
            SubTransactionSummary(
                id: "regular",
                amount: Money(milliunits: -40_000),
                categoryId: "household",
                categoryName: "Household",
                forecastTreatment: .ordinarySpending,
                payeeName: nil,
                memo: nil,
                deleted: false
            )
        ])

        let entries = SpendingEntryPipeline.assembleEntries(
            rows: [row],
            context: context
        )

        #expect(entries.count == 1)
        #expect(entries.first?.categoryName == "Household")
        #expect(
            entries.first?.groupIdentity
                == SpendingGroupSetup.unassignedIdentity
        )
    }

    private func account(
        id: String,
        type: FinancialAccountType
    ) -> CachedFinancialAccount {
        CachedFinancialAccount(
            canonicalAccountId: id,
            externalId: "plaid-\(id)",
            itemId: "item",
            source: .plaid,
            institutionName: "Bank",
            name: id.capitalized,
            officialName: nil,
            mask: nil,
            type: type,
            subtype: nil,
            currentBalanceMilliunits: 1_000_000,
            availableBalanceMilliunits: 1_000_000,
            creditLimitMilliunits: nil,
            isoCurrencyCode: "USD"
        )
    }

    private func transaction(
        id: String,
        accountID: String,
        treatment: ForecastTreatment
    ) -> CachedFinancialTransaction {
        let summary = FinancialTransactionSummary(
            id: id,
            externalId: id,
            source: .plaid,
            accountId: accountID,
            postedDate: .now,
            authorizedDate: nil,
            amount: Money(milliunits: -100_000),
            pending: false,
            pendingTransactionId: nil,
            rawDescription: id,
            originalDescription: nil,
            providerMerchantName: nil,
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
        return CachedFinancialTransaction(
            summary: summary,
            classification: TransactionClassification(
                displayName: id,
                categoryName: treatment == .ordinarySpending
                    ? "Other" : nil,
                treatment: treatment,
                confidence: .high,
                provenance: .user,
                requiresReview: false
            ),
            requiresNameReview: false
        )
    }
}
