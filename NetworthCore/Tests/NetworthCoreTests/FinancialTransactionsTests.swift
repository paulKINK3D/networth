import Foundation
import Testing
@testable import NetworthCore

@Suite("Source-neutral financial transactions")
struct FinancialTransactionsTests {
    @Test func plaidAmountIsNormalizedToNetworthSignConvention() throws {
        let dto = PlaidTransactionDTO(
            id: "transaction-1",
            accountId: "plaid-account",
            date: "2026-07-24",
            amount: 42.50,
            name: "Merchant"
        )

        let summary = try #require(dto.financialSummary(canonicalAccountId: "canonical-account"))
        #expect(summary.amount == Money.dollars(-42.50))
        #expect(summary.accountId == "canonical-account")
    }

    @Test func plaidCreditBalanceIsNormalizedAsLiability() {
        let dto = PlaidAccountDTO(
            id: "card-1",
            itemId: "item-1",
            institutionName: "Example Bank",
            name: "Card",
            officialName: nil,
            mask: "1234",
            type: "credit",
            subtype: "credit card",
            currentBalance: 825.40,
            availableBalance: 4_174.60,
            limit: 5_000,
            isoCurrencyCode: "USD",
            unofficialCurrencyCode: nil
        )

        let account = dto.financialSummary(canonicalAccountId: "canonical-card")

        #expect(account.type == .creditCard)
        #expect(account.currentBalance == Money.dollars(-825.40))
        #expect(account.availableBalance == Money.dollars(4_174.60))
        #expect(account.creditLimit == Money.dollars(5_000))
    }

    @Test func stableMerchantEntityWinsOverMessyDescription() {
        let transaction = plaidTransaction(
            rawDescription: "SQ *JOES PIZZA 1842",
            merchantName: "Joe's Pizza",
            merchantEntityId: "ENTITY-123"
        )

        #expect(transaction.merchantFingerprint == "merchant:entity-123")
        #expect(transaction.fallbackDisplayName == "Joe's Pizza")
    }

    @Test func volatileBankReferenceNumbersDoNotSplitMerchantFingerprint() {
        let first = plaidTransaction(
            rawDescription: """
            APA TREAS 310 DES:MISC PAY ID:RSXXXXX00029867 \
            INDN:Botto,Paul CO ID:XXXXX36151 PPD
            """
        )
        let second = plaidTransaction(
            rawDescription: """
            APA TREAS 310 DES:MISC PAY ID:RSXXXXX00032969 \
            INDN:Botto,Paul CO ID:XXXXX47262 PPD
            """
        )

        #expect(first.merchantFingerprint == second.merchantFingerprint)
        #expect(
            first.merchantFingerprint
                == "description:apa treas 310 des misc pay id indn botto paul co id ppd"
        )
    }

    @Test func historicalMatcherPairsUniqueAmountDateAndName() {
        let legacy = [
            legacyTransaction(
                id: "ynab-1",
                accountId: "ynab-checking",
                date: date(2026, 7, 23),
                amount: -42_500,
                payee: "Joe's Pizza"
            )
        ]
        let plaid = [
            plaidTransaction(
                id: "plaid-1",
                accountId: "canonical-checking",
                date: date(2026, 7, 24),
                amount: -42_500,
                rawDescription: "SQ *JOES PIZZA 1842",
                merchantName: "Joe's Pizza"
            )
        ]

        let match = HistoricalTransactionMatcher().matches(
            legacy: legacy,
            plaid: plaid,
            canonicalAccountIdByYNABId: ["ynab-checking": "canonical-checking"]
        ).first

        #expect(match?.legacyTransactionId == "ynab-1")
        #expect(match?.plaidTransactionId == "plaid-1")
        #expect(match?.isAutomatic == true)
        #expect(match?.confidence == .high)
    }

    @Test func historicalMatcherAllowsExactNameAcrossPostingDelay() {
        let legacy = [
            legacyTransaction(
                id: "ynab-delayed",
                accountId: "ynab-card",
                date: date(2026, 7, 21),
                amount: -42_500,
                payee: "Joe's Pizza"
            )
        ]
        let plaid = [
            plaidTransaction(
                id: "plaid-delayed",
                accountId: "canonical-card",
                date: date(2026, 7, 24),
                amount: -42_500,
                rawDescription: "SQ *JOES PIZZA 1842",
                merchantName: "Joe's Pizza"
            )
        ]

        let match = HistoricalTransactionMatcher().matches(
            legacy: legacy,
            plaid: plaid,
            canonicalAccountIdByYNABId: [
                "ynab-card": "canonical-card"
            ]
        ).first

        #expect(match?.isAutomatic == true)
        #expect(match?.confidence == .high)
    }

    @Test func historicalMatcherTrustsSingleCandidateDespiteMessyPlaidName() {
        let legacy = [
            legacyTransaction(
                id: "ynab-messy-name",
                accountId: "ynab-card",
                date: date(2026, 7, 22),
                amount: -86_420,
                payee: "Local YNAB Payee"
            )
        ]
        let plaid = [
            plaidTransaction(
                id: "plaid-messy-name",
                accountId: "canonical-card",
                date: date(2026, 7, 24),
                amount: -86_420,
                rawDescription: "TST* 984723 NY",
                merchantName: "Completely Different Institution Text"
            )
        ]

        let match = HistoricalTransactionMatcher().matches(
            legacy: legacy,
            plaid: plaid,
            canonicalAccountIdByYNABId: [
                "ynab-card": "canonical-card"
            ]
        ).first

        #expect(match?.isAutomatic == true)
        #expect(match?.confidence == .high)
    }

    @Test func historicalMatcherConfirmsSingleSimilarNameCandidate() {
        let legacy = [
            legacyTransaction(
                id: "ynab-1",
                accountId: "ynab-card",
                date: date(2026, 7, 22),
                amount: -75_250,
                payee: "Trader Joe's"
            )
        ]
        let plaid = [
            plaidTransaction(
                id: "plaid-1",
                accountId: "canonical-card",
                date: date(2026, 7, 24),
                amount: -75_250,
                rawDescription: "TRADER JOES #123",
                merchantName: "Trader Joe's #123"
            )
        ]

        let match = HistoricalTransactionMatcher().matches(
            legacy: legacy,
            plaid: plaid,
            canonicalAccountIdByYNABId: ["ynab-card": "canonical-card"]
        ).first

        #expect(match?.isAutomatic == true)
        #expect(match?.confidence == .high)
    }

    @Test func historicalMatcherAcceptsEquivalentDuplicateCandidates() {
        let legacy = [
            legacyTransaction(
                id: "ynab-1",
                accountId: "ynab-card",
                date: date(2026, 7, 24),
                amount: -10_000,
                payee: "Coffee"
            ),
            legacyTransaction(
                id: "ynab-2",
                accountId: "ynab-card",
                date: date(2026, 7, 24),
                amount: -10_000,
                payee: "Coffee"
            )
        ]
        let plaid = [
            plaidTransaction(
                accountId: "canonical-card",
                date: date(2026, 7, 24),
                amount: -10_000,
                rawDescription: "Coffee"
            )
        ]

        let match = HistoricalTransactionMatcher().matches(
            legacy: legacy,
            plaid: plaid,
            canonicalAccountIdByYNABId: ["ynab-card": "canonical-card"]
        ).first

        #expect(match?.isAutomatic == true)
    }

    @Test func historicalMatcherUsesAuthorizedDatesForRepeatedPurchases() {
        let legacy = [
            legacyTransaction(
                id: "ynab-jan-29",
                accountId: "ynab-card",
                date: date(2026, 1, 29),
                amount: -8_750,
                payee: "Bright Coffee",
                categoryName: "Coffee"
            ),
            legacyTransaction(
                id: "ynab-jan-30",
                accountId: "ynab-card",
                date: date(2026, 1, 30),
                amount: -8_750,
                payee: "Bright Coffee",
                categoryName: "Coffee"
            )
        ]
        let plaid = [
            plaidTransaction(
                id: "plaid-jan-29",
                accountId: "canonical-card",
                date: date(2026, 1, 31),
                authorizedDate: date(2026, 1, 29),
                amount: -8_750,
                rawDescription: "BRIGHT COFFEE",
                merchantName: "Bright Coffee"
            ),
            plaidTransaction(
                id: "plaid-jan-30",
                accountId: "canonical-card",
                date: date(2026, 1, 31),
                authorizedDate: date(2026, 1, 30),
                amount: -8_750,
                rawDescription: "BRIGHT COFFEE",
                merchantName: "Bright Coffee"
            )
        ]

        let matches = HistoricalTransactionMatcher().matches(
            legacy: legacy,
            plaid: plaid,
            canonicalAccountIdByYNABId: [
                "ynab-card": "canonical-card"
            ]
        )

        #expect(matches.count == 2)
        #expect(matches.allSatisfy { $0.isAutomatic })
        #expect(
            matches.first {
                $0.plaidTransactionId == "plaid-jan-29"
            }?.legacyTransactionId == "ynab-jan-29"
        )
        #expect(
            matches.first {
                $0.plaidTransactionId == "plaid-jan-30"
            }?.legacyTransactionId == "ynab-jan-30"
        )
    }

    @Test func historicalMatcherAlsoAcceptsCloserPostedDate() {
        let legacy = [
            legacyTransaction(
                id: "ynab-parking",
                accountId: "ynab-card",
                date: date(2024, 8, 13),
                amount: -3_250,
                payee: "Parking",
                categoryName: "Social - Personal"
            )
        ]
        let plaid = [
            plaidTransaction(
                id: "plaid-parking",
                accountId: "canonical-card",
                date: date(2024, 8, 11),
                authorizedDate: date(2024, 8, 9),
                amount: -3_250,
                rawDescription: "PARKING",
                merchantName: "Parking"
            )
        ]

        let match = HistoricalTransactionMatcher().matches(
            legacy: legacy,
            plaid: plaid,
            canonicalAccountIdByYNABId: [
                "ynab-card": "canonical-card"
            ]
        ).first

        #expect(match?.legacyTransactionId == "ynab-parking")
        #expect(match?.isAutomatic == true)
    }

    @Test func historicalMatcherRefusesDifferentCandidateOutcomes() {
        let legacy = [
            legacyTransaction(
                id: "ynab-coffee",
                accountId: "ynab-card",
                date: date(2026, 7, 24),
                amount: -10_000,
                payee: "Example Store",
                categoryName: "Coffee"
            ),
            legacyTransaction(
                id: "ynab-household",
                accountId: "ynab-card",
                date: date(2026, 7, 24),
                amount: -10_000,
                payee: "Example Store",
                categoryName: "Household"
            )
        ]
        let plaid = [
            plaidTransaction(
                accountId: "canonical-card",
                date: date(2026, 7, 24),
                amount: -10_000,
                rawDescription: "Example Store",
                merchantName: "Example Store"
            )
        ]

        let match = HistoricalTransactionMatcher().matches(
            legacy: legacy,
            plaid: plaid,
            canonicalAccountIdByYNABId: [
                "ynab-card": "canonical-card"
            ]
        ).first

        #expect(match?.isAutomatic == false)
    }

    @Test func confirmedRuleIsAutomaticAndAuthoritative() {
        let transaction = plaidTransaction(
            merchantName: "TRADER JOES #123",
            merchantEntityId: "trader-joes",
            categoryPrimary: "FOOD_AND_DRINK",
            categoryDetailed: "FOOD_AND_DRINK_GROCERIES",
            categoryConfidence: "VERY_HIGH"
        )
        let rule = MerchantClassificationRule(
            fingerprint: transaction.merchantFingerprint,
            preferredName: "Trader Joe's",
            category: .groceries,
            categoryName: "Groceries & Household",
            treatment: .ordinarySpending,
            provenance: .user,
            confirmed: true
        )

        let result = TransactionClassifier().classify(transaction, rules: [rule])

        #expect(result.displayName == "Trader Joe's")
        #expect(result.category == .groceries)
        #expect(result.categoryName == "Groceries & Household")
        #expect(result.provenance == .confirmedRule)
        #expect(result.requiresReview == false)
    }

    @Test func nameOnlyRuleReusesNameButRequiresCategoryReview() {
        let transaction = plaidTransaction(
            merchantName: "TARGET 1234",
            merchantEntityId: "target",
            categoryPrimary: "GENERAL_MERCHANDISE",
            categoryDetailed: "GENERAL_MERCHANDISE_SUPERSTORES",
            categoryConfidence: "VERY_HIGH"
        )
        let rule = MerchantClassificationRule(
            fingerprint: transaction.merchantFingerprint,
            preferredName: "Target",
            category: .groceries,
            categoryName: "Groceries",
            treatment: .ordinarySpending,
            categoryReusable: false,
            provenance: .user,
            confirmed: true
        )

        let result = TransactionClassifier().classify(transaction, rules: [rule])

        #expect(result.displayName == "Target")
        #expect(result.category == .shopping)
        #expect(result.requiresReview)
    }

    @Test func reusableRuleReturnsForReviewWhenPlaidStronglyContradictsIt() {
        let transaction = plaidTransaction(
            merchantName: "VARIABLE MERCHANT",
            merchantEntityId: "variable",
            categoryPrimary: "TRANSPORTATION",
            categoryDetailed: "TRANSPORTATION_TAXIS_AND_RIDE_SHARES",
            categoryConfidence: "HIGH"
        )
        let rule = MerchantClassificationRule(
            fingerprint: transaction.merchantFingerprint,
            preferredName: "Variable Merchant",
            category: .dining,
            categoryName: "Dining Out",
            treatment: .ordinarySpending,
            categoryReusable: true,
            provenance: .user,
            confirmed: true
        )

        let result = TransactionClassifier().classify(transaction, rules: [rule])

        #expect(result.displayName == "Variable Merchant")
        #expect(result.category == .transportation)
        #expect(result.requiresReview)
    }

    @Test func agreeingHighConfidenceModelAndPlaidCanAutoApply() {
        let transaction = plaidTransaction(
            merchantName: "Joe's Pizza",
            categoryPrimary: "FOOD_AND_DRINK",
            categoryDetailed: "FOOD_AND_DRINK_RESTAURANTS",
            categoryConfidence: "HIGH"
        )
        let model = ModelClassificationSuggestion(
            displayName: "Joe's Pizza",
            category: .dining,
            confidence: .high,
            provenance: .appleModel
        )

        let result = TransactionClassifier().classify(
            transaction,
            rules: [],
            modelSuggestion: model
        )

        #expect(result.category == .dining)
        #expect(result.confidence == .high)
        #expect(result.requiresReview == false)
    }

    @Test func disagreementAlwaysRequiresReview() {
        let transaction = plaidTransaction(
            merchantName: "Target",
            categoryPrimary: "GENERAL_MERCHANDISE",
            categoryDetailed: "GENERAL_MERCHANDISE_SUPERSTORES",
            categoryConfidence: "VERY_HIGH"
        )
        let model = ModelClassificationSuggestion(
            displayName: "Target",
            category: .groceries,
            confidence: .high,
            provenance: .claude
        )

        let result = TransactionClassifier().classify(
            transaction,
            rules: [],
            modelSuggestion: model
        )

        #expect(result.category == .groceries)
        #expect(result.requiresReview == true)
    }

    @Test func plaidTransfersAndCardPaymentsDoNotBecomeOrdinarySpending() {
        let transfer = plaidTransaction(
            amount: -50_000,
            categoryPrimary: "TRANSFER_OUT",
            categoryDetailed: "TRANSFER_OUT_ACCOUNT_TRANSFER"
        )
        let cardPayment = plaidTransaction(
            amount: -200_000,
            categoryPrimary: "LOAN_PAYMENTS",
            categoryDetailed: "LOAN_PAYMENTS_CREDIT_CARD_PAYMENT"
        )
        let classifier = TransactionClassifier()

        #expect(classifier.forecastTreatment(for: transfer) == .internalTransfer)
        #expect(classifier.forecastTreatment(for: cardPayment) == .cardPayment)
    }

    @Test func positiveNonIncomeTransactionDefaultsToRefund() {
        let classifier = TransactionClassifier()
        let refund = plaidTransaction(
            amount: 20_000,
            categoryPrimary: "GENERAL_MERCHANDISE",
            categoryDetailed: "GENERAL_MERCHANDISE_OTHER_GENERAL_MERCHANDISE"
        )
        let unknownRefund = plaidTransaction(amount: 20_000)
        let categorized = classifier.classify(refund, rules: [])
        let uncategorized = classifier.classify(unknownRefund, rules: [])

        #expect(categorized.treatment == .refund)
        #expect(categorized.category == .shopping)
        #expect(uncategorized.treatment == .refund)
        #expect(uncategorized.category == .other)
    }

    @Test func reimbursementCategoryIsAvailableAndRecognized() {
        let classifier = TransactionClassifier()

        #expect(NativeTransactionCategory.reimbursements.displayName == "Reimbursements")
        #expect(
            classifier.nativeCategory(
                primary: "REIMBURSEMENTS",
                detailed: nil
            ) == .reimbursements
        )
    }

    @Test func discretionaryBudgetCountsSelectedCurrentMonthSpendingAndRefunds() {
        let transactions = [
            budgetTransaction(
                id: "coffee",
                date: date(2026, 7, 2),
                amount: -20_000,
                categoryId: "coffee",
                categoryName: "Coffee"
            ),
            budgetTransaction(
                id: "coffee-refund",
                date: date(2026, 7, 8),
                amount: 5_000,
                categoryId: "coffee",
                categoryName: "Coffee"
            ),
            budgetTransaction(
                id: "rent",
                date: date(2026, 7, 1),
                amount: -1_500_000,
                categoryId: "rent",
                categoryName: "Rent"
            ),
            budgetTransaction(
                id: "old-coffee",
                date: date(2026, 6, 30),
                amount: -10_000,
                categoryId: "coffee",
                categoryName: "Coffee"
            ),
            budgetTransaction(
                id: "transfer",
                date: date(2026, 7, 4),
                amount: -200_000,
                categoryId: "coffee",
                categoryName: "Coffee",
                transferAccountId: "savings"
            ),
            budgetTransaction(
                id: "income",
                date: date(2026, 7, 5),
                amount: 1_000_000,
                categoryId: "coffee",
                categoryName: "Coffee",
                forecastTreatment: .income
            )
        ]

        let result = DiscretionaryBudgetCalculator().snapshot(
            transactions: transactions,
            discretionaryCategoryIds: ["coffee"],
            target: Money.dollars(300),
            asOf: date(2026, 7, 15),
            calendar: utcCalendar
        )

        #expect(result.spent == Money.dollars(15))
        #expect(result.remaining == Money.dollars(285))
    }

    @Test func discretionaryBudgetUsesSplitLegCategoriesInsteadOfParent() {
        let transaction = TransactionSummary(
            id: "split",
            accountId: "card",
            date: date(2026, 7, 10),
            amount: Money.dollars(-100),
            cleared: true,
            approved: true,
            payeeName: "Store",
            categoryId: "discretionary",
            categoryName: "Discretionary Parent",
            memo: nil,
            deleted: false,
            subtransactions: [
                SubTransactionSummary(
                    id: "coffee-leg",
                    amount: Money.dollars(-25),
                    categoryId: "coffee",
                    categoryName: "Coffee",
                    payeeName: nil,
                    memo: nil,
                    deleted: false
                ),
                SubTransactionSummary(
                    id: "household-leg",
                    amount: Money.dollars(-65),
                    categoryId: "household",
                    categoryName: "Household",
                    payeeName: nil,
                    memo: nil,
                    deleted: false
                ),
                SubTransactionSummary(
                    id: "transfer-leg",
                    amount: Money.dollars(-10),
                    categoryId: "coffee",
                    categoryName: "Coffee",
                    forecastTreatment: .internalTransfer,
                    payeeName: nil,
                    memo: nil,
                    deleted: false
                )
            ]
        )

        let result = DiscretionaryBudgetCalculator().snapshot(
            transactions: [transaction],
            discretionaryCategoryIds: ["coffee", "discretionary"],
            target: Money.dollars(100),
            asOf: date(2026, 7, 15),
            calendar: utcCalendar
        )

        #expect(result.spent == Money.dollars(25))

        let breakdown = DiscretionaryBudgetCalculator().breakdown(
            transactions: [transaction],
            discretionaryCategoryIds: ["coffee", "discretionary"],
            asOf: date(2026, 7, 15),
            calendar: utcCalendar
        )
        #expect(breakdown.count == 1)
        #expect(breakdown.first?.name == "Coffee")
        #expect(breakdown.first?.amount == Money.dollars(25))
    }

    @Test func discretionaryBudgetPaceUsesElapsedDaysInMonth() {
        let result = DiscretionaryBudgetCalculator().snapshot(
            transactions: [],
            discretionaryCategoryIds: [],
            target: Money.dollars(310),
            asOf: date(2026, 7, 15),
            calendar: utcCalendar
        )

        #expect(result.daysElapsed == 15)
        #expect(result.daysInMonth == 31)
        #expect(result.paceTarget == Money.dollars(150))
        #expect(result.paceDifference == Money.dollars(-150))
    }

    @Test func discretionaryBudgetHistoricalAverageUsesThreeCompletedMonths() {
        let transactions = [
            budgetTransaction(
                id: "april",
                date: date(2026, 4, 10),
                amount: -100_000,
                categoryId: "coffee",
                categoryName: "Coffee"
            ),
            budgetTransaction(
                id: "may",
                date: date(2026, 5, 10),
                amount: -200_000,
                categoryId: "coffee",
                categoryName: "Coffee"
            ),
            budgetTransaction(
                id: "june",
                date: date(2026, 6, 10),
                amount: -300_000,
                categoryId: "coffee",
                categoryName: "Coffee"
            ),
            budgetTransaction(
                id: "current-month-is-excluded",
                date: date(2026, 7, 10),
                amount: -900_000,
                categoryId: "coffee",
                categoryName: "Coffee"
            ),
            budgetTransaction(
                id: "older-month-is-excluded",
                date: date(2026, 3, 10),
                amount: -900_000,
                categoryId: "coffee",
                categoryName: "Coffee"
            ),
            budgetTransaction(
                id: "fixed-is-excluded",
                date: date(2026, 6, 1),
                amount: -1_500_000,
                categoryId: "rent",
                categoryName: "Rent"
            ),
            budgetTransaction(
                id: "manual-balance-adjustment-is-excluded",
                date: date(2026, 5, 5),
                amount: -300_000_000,
                categoryId: "uncategorized",
                categoryName: "Uncategorized",
                payeeName: "Manual Balance Adjustment"
            ),
            budgetTransaction(
                id: "investment-adjustment-is-excluded",
                date: date(2026, 5, 5),
                amount: -75_000_000,
                categoryId: "investing",
                categoryName: "Investing",
                payeeName: "Investment"
            )
        ]

        let calculator = DiscretionaryBudgetCalculator()
        let selectedCategories: Set<String> = [
            "coffee",
            "uncategorized",
            "investing"
        ]
        let average = calculator.historicalMonthlyAverage(
            transactions: transactions,
            discretionaryCategoryIds: selectedCategories,
            completedMonthCount: 3,
            asOf: date(2026, 7, 15),
            calendar: utcCalendar
        )
        let totals = calculator.historicalCategoryTotals(
            transactions: transactions,
            discretionaryCategoryIds: selectedCategories,
            completedMonthCount: 3,
            asOf: date(2026, 7, 15),
            calendar: utcCalendar
        )

        #expect(average == Money.dollars(200))
        #expect(totals.count == 1)
        #expect(totals.first?.name == "Coffee")
        #expect(totals.first?.amount == Money.dollars(600))
    }

    @Test func discretionaryBudgetDefaultsMatchConfirmedCategoryMapping() {
        #expect(DiscretionaryBudgetDefaults.includesCategory(
            name: "Gym/Biking/Exercise",
            groupName: "Fixed"
        ))
        #expect(DiscretionaryBudgetDefaults.includesCategory(
            name: "Investing",
            groupName: "Savings"
        ))
        #expect(DiscretionaryBudgetDefaults.includesCategory(
            name: "Dates",
            groupName: "Surplus"
        ))
        #expect(!DiscretionaryBudgetDefaults.includesCategory(
            name: "Lyft/Uber",
            groupName: "Transportation"
        ))
        #expect(!DiscretionaryBudgetDefaults.includesCategory(
            name: "Reimbursement - $15K",
            groupName: "Working"
        ))
    }

    @Test func splitLegTreatmentPersistsAndOlderPayloadsRemainReadable() throws {
        let leg = SubTransactionSummary(
            id: "split-income",
            amount: Money.dollars(80),
            categoryId: nil,
            categoryName: "Income",
            forecastTreatment: .income,
            payeeName: nil,
            memo: nil,
            deleted: false
        )
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let roundTrip = try decoder.decode(
            SubTransactionSummary.self,
            from: encoder.encode(leg)
        )
        #expect(roundTrip.forecastTreatment == .income)

        var legacyObject = try #require(
            JSONSerialization.jsonObject(
                with: encoder.encode(leg)
            ) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "forecastTreatment")
        let legacyData = try JSONSerialization.data(
            withJSONObject: legacyObject
        )
        let legacy = try decoder.decode(
            SubTransactionSummary.self,
            from: legacyData
        )
        #expect(legacy.forecastTreatment == nil)
    }

    @Test func canonicalContactLookupAcceptsOnlyTokenBoundaryVariants() {
        #expect(
            FinancialTransactionSummary.namesReferToSamePayee(
                "Gusto",
                "Gusto Payroll"
            )
        )
        #expect(
            !FinancialTransactionSummary.namesReferToSamePayee(
                "Payment",
                "Payment Services"
            )
        )
        #expect(
            !FinancialTransactionSummary.namesReferToSamePayee(
                "Target",
                "Targeted Marketing"
            )
        )
    }

    @Test func claudeSnapshotContractContainsOnlyUserFacingRecords() throws {
        let snapshot = ClaudeFinancialSnapshotDTO(
            generatedAt: date(2026, 7, 30),
            primarySource: "plaid",
            accounts: [
                ClaudeAccountDTO(
                    name: "Checking",
                    institutionName: "Example Bank",
                    type: "checking",
                    balanceMilliunits: 1_000_000,
                    availableBalanceMilliunits: 900_000,
                    closed: false
                )
            ],
            manualAssets: [],
            holdings: [],
            transactions: [],
            netWorthHistory: []
        )

        let data = try JSONEncoder().encode(snapshot)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(json.contains("\"schemaVersion\":1"))
        #expect(json.contains("\"name\":\"Checking\""))
        #expect(!json.contains("accountId"))
        #expect(!json.contains("accessToken"))
        #expect(!json.contains("rawDescription"))
    }

    private func plaidTransaction(
        id: String = "plaid-transaction",
        accountId: String = "canonical-account",
        date: Date = date(2026, 7, 24),
        authorizedDate: Date? = nil,
        amount: Int64 = -20_000,
        rawDescription: String = "RAW MERCHANT",
        merchantName: String? = nil,
        merchantEntityId: String? = nil,
        categoryPrimary: String? = nil,
        categoryDetailed: String? = nil,
        categoryConfidence: String? = nil
    ) -> FinancialTransactionSummary {
        FinancialTransactionSummary(
            id: id,
            externalId: id,
            source: .plaid,
            accountId: accountId,
            postedDate: date,
            authorizedDate: authorizedDate,
            amount: Money(milliunits: amount),
            pending: false,
            pendingTransactionId: nil,
            rawDescription: rawDescription,
            originalDescription: rawDescription,
            providerMerchantName: merchantName,
            merchantEntityId: merchantEntityId,
            counterpartyName: nil,
            counterpartyType: nil,
            counterpartyEntityId: nil,
            counterpartyConfidence: nil,
            paymentChannel: nil,
            providerCategoryPrimary: categoryPrimary,
            providerCategoryDetailed: categoryDetailed,
            providerCategoryConfidence: categoryConfidence,
            transactionCode: nil
        )
    }

    private func legacyTransaction(
        id: String,
        accountId: String,
        date: Date,
        amount: Int64,
        payee: String,
        categoryName: String = "Legacy"
    ) -> TransactionSummary {
        TransactionSummary(
            id: id,
            accountId: accountId,
            date: date,
            amount: Money(milliunits: amount),
            cleared: true,
            approved: true,
            payeeName: payee,
            categoryName: categoryName,
            memo: nil,
            deleted: false
        )
    }

    private func budgetTransaction(
        id: String,
        date: Date,
        amount: Int64,
        categoryId: String?,
        categoryName: String?,
        forecastTreatment: ForecastTreatment? = nil,
        transferAccountId: String? = nil,
        payeeName: String = "Payee"
    ) -> TransactionSummary {
        TransactionSummary(
            id: id,
            accountId: "checking",
            date: date,
            amount: Money(milliunits: amount),
            cleared: true,
            approved: true,
            payeeName: payeeName,
            categoryId: categoryId,
            categoryName: categoryName,
            forecastTreatment: forecastTreatment,
            transferAccountId: transferAccountId,
            memo: nil,
            deleted: false
        )
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

}

private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
    Calendar(identifier: .gregorian).date(
        from: DateComponents(
            timeZone: TimeZone(secondsFromGMT: 0),
            year: year,
            month: month,
            day: day
        )
    )!
}
