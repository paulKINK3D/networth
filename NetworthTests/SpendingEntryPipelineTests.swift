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

    @Test func reimbursementsStayOutsideSpending() {
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
        treatment: ForecastTreatment,
        category: NativeTransactionCategory = .other
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
                category: category,
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
