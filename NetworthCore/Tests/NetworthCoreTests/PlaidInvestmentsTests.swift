import Foundation
import Testing
@testable import NetworthCore

@Suite("Plaid investment normalization")
struct PlaidInvestmentsTests {
    @Test func decimalValuesRoundToMilliunitsWithoutDoubleConversion() {
        let account = accountDTO(currentBalance: Decimal(string: "1234.5678")!)
        let holding = holdingDTO(value: Decimal(string: "1200.1236")!)

        #expect(account.summary.currentBalance == Money(milliunits: 1_234_568))
        #expect(holding.summary.institutionValue == Money(milliunits: 1_200_124))
    }

    @Test func accountBalanceReconcilesHoldingsAndResidualCash() throws {
        let snapshot = PlaidHoldingsResponseDTO(
            items: [itemDTO()],
            accounts: [accountDTO(currentBalance: 10_000)],
            securities: [],
            holdings: [
                holdingDTO(securityId: "security-1", value: 6_000),
                holdingDTO(securityId: "security-2", value: 3_500)
            ]
        ).toSnapshot()

        let reconciliation = try #require(snapshot.reconciliation(for: "account-1"))
        #expect(reconciliation.accountBalance == Money.dollars(10_000))
        #expect(reconciliation.holdingsValue == Money.dollars(9_500))
        #expect(reconciliation.residual == Money.dollars(500))
    }

    @Test func onlyReviewedIncludedUSDAccountsContributeToNetWorth() {
        let pending = accountDTO(id: "pending", currentBalance: 10_000).summary
        let included = accountDTO(id: "included", currentBalance: 20_000).summary
        let duplicate = accountDTO(id: "duplicate", currentBalance: 30_000).summary
        let nonUSD = accountDTO(
            id: "non-usd",
            currentBalance: 40_000,
            isoCurrencyCode: "EUR"
        ).summary
        let snapshot = PlaidInvestmentSnapshot(
            items: [],
            accounts: [pending, included, duplicate, nonUSD],
            securities: [],
            holdings: []
        )

        let contribution = snapshot.netWorthContribution(treatments: [
            "pending": .pendingReview,
            "included": .included,
            "duplicate": .duplicateYNAB,
            "non-usd": .included
        ])

        #expect(contribution == Money.dollars(50_000))
    }

    @Test func unofficialCurrencyIsUnsupportedEvenWhenISOCodeIsUSD() {
        let account = accountDTO(
            currentBalance: 1_000,
            isoCurrencyCode: "USD",
            unofficialCurrencyCode: "BTC"
        ).summary

        #expect(account.usesSupportedCurrency == false)
    }

    @Test func retirementClassifierRecognizesPlaidIRASubtypes() {
        #expect(PlaidRetirementClassifier.isRetirement(subtype: "ira"))
        #expect(PlaidRetirementClassifier.isRetirement(subtype: " Roth "))
        #expect(PlaidRetirementClassifier.isRetirement(subtype: "401K"))
        #expect(!PlaidRetirementClassifier.isRetirement(subtype: "brokerage"))
        #expect(!PlaidRetirementClassifier.isRetirement(subtype: nil))
    }

    @Test func investmentCategoryScopesKeepRetirementSeparate() {
        #expect(InvestmentCategoryScope.investments.includesLegacyInvestmentAccounts)
        #expect(!InvestmentCategoryScope.retirement.includesLegacyInvestmentAccounts)

        #expect(InvestmentCategoryScope.investments.includes(manualAssetKind: .brokerage))
        #expect(InvestmentCategoryScope.investments.includes(manualAssetKind: .crypto))
        #expect(!InvestmentCategoryScope.investments.includes(manualAssetKind: .retirement))
        #expect(InvestmentCategoryScope.retirement.includes(manualAssetKind: .retirement))

        #expect(InvestmentCategoryScope.investments.includes(plaidSubtype: "brokerage"))
        #expect(!InvestmentCategoryScope.investments.includes(plaidSubtype: "ira"))
        #expect(InvestmentCategoryScope.retirement.includes(plaidSubtype: "401k"))
        #expect(!InvestmentCategoryScope.retirement.includes(plaidSubtype: nil))
    }

    private func itemDTO() -> PlaidItemDTO {
        PlaidItemDTO(
            id: "item-1",
            institutionName: "First Brokerage",
            status: "healthy",
            lastSyncedAt: nil
        )
    }

    private func accountDTO(
        id: String = "account-1",
        currentBalance: Decimal,
        isoCurrencyCode: String? = "USD",
        unofficialCurrencyCode: String? = nil
    ) -> PlaidAccountDTO {
        PlaidAccountDTO(
            id: id,
            itemId: "item-1",
            institutionName: "First Brokerage",
            name: "Brokerage",
            officialName: nil,
            mask: "1234",
            subtype: "brokerage",
            currentBalance: currentBalance,
            availableBalance: nil,
            isoCurrencyCode: isoCurrencyCode,
            unofficialCurrencyCode: unofficialCurrencyCode
        )
    }

    private func holdingDTO(
        securityId: String = "security-1",
        value: Decimal
    ) -> PlaidHoldingDTO {
        PlaidHoldingDTO(
            accountId: "account-1",
            securityId: securityId,
            quantity: 10,
            institutionValue: value,
            costBasis: nil,
            asOf: nil
        )
    }
}
