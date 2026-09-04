import Foundation
import Testing
import SwiftData
@testable import Networth
import NetworthCore

@MainActor
@Suite("AppContainer wiring")
struct AppContainerTests {

    @Test func ynabRetirementPurgesOnlyDisposableLocalRows() throws {
        let container = AppContainerController.makePreview()
        let context = container.modelContainer.mainContext
        context.insert(CachedAccount(
            id: "legacy-account",
            budgetId: "legacy-budget",
            name: "Legacy Checking",
            typeRaw: "checking",
            balanceMilliunits: 0,
            clearedMilliunits: 0,
            unclearedMilliunits: 0,
            onBudget: true,
            closed: false,
            deleted: false
        ))
        context.insert(YNABReferenceSuggestion(
            plaidTransactionId: "plaid-transaction",
            ynabTransactionId: "legacy-transaction",
            payeeNameSnapshot: "Coffee"
        ))
        context.insert(DurableCanonicalPayee(
            canonicalId: "stable-contact",
            name: "Coffee",
            sourceName: "Coffee"
        ))
        context.insert(DurableCanonicalTransactionDecision(
            transactionExternalId: "plaid-transaction",
            payeeCanonicalId: "stable-contact",
            payeeNameSnapshot: "Coffee",
            amountSign: -1,
            forecastTreatment: .ordinarySpending,
            reviewed: true,
            provenance: .user
        ))
        context.insert(CachedFinancialAccount(
            canonicalAccountId: "stable-account",
            externalId: "plaid-account",
            itemId: "plaid-item",
            source: .plaid,
            institutionName: "Bank",
            name: "Checking",
            officialName: nil,
            mask: nil,
            type: .checking,
            subtype: "checking",
            currentBalanceMilliunits: 0,
            availableBalanceMilliunits: 0,
            creditLimitMilliunits: nil,
            isoCurrencyCode: "USD"
        ))
        try context.save()

        let suiteName = "AppContainerTests.ynabRetirement.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(container.retireYNABLocalDataIfNeeded(defaults: defaults))
        #expect(container.retireYNABLocalDataIfNeeded(defaults: defaults))
        #expect(try context.fetch(FetchDescriptor<CachedAccount>()).isEmpty)
        #expect(try context.fetch(
            FetchDescriptor<YNABReferenceSuggestion>()
        ).isEmpty)
        #expect(try context.fetch(
            FetchDescriptor<DurableCanonicalPayee>()
        ).count == 1)
        #expect(try context.fetch(
            FetchDescriptor<DurableCanonicalTransactionDecision>()
        ).count == 1)
        #expect(try context.fetch(
            FetchDescriptor<CachedFinancialAccount>()
        ).count == 1)
    }

    @Test func bootstrapWithBiometricAvailableLocksUntilUnlock() async {
        // With biometrics available (the ScriptableBiometricGate default) and
        // the shipped Face-ID-on-by-default behavior, bootstrap should leave
        // the app locked behind the biometric prompt regardless of token state.
        let container = AppContainerController.makePreview()
        await container.bootstrap()
        #expect(container.unlocked == false)
    }

    @Test func bootstrapWithBiometricUnavailableLeavesUnlocked() async {
        // When the device cannot use biometrics, the Face ID gate cannot
        // engage and the app must boot straight into the tabs.
        let container = AppContainerController(
            secretStore: InMemorySecretStore(),
            biometricGate: ScriptableBiometricGate(isAvailable: false),
            modelContainer: try! ModelContainerFactory.makeContainer(inMemory: true)
        )
        await container.bootstrap()
        #expect(container.unlocked == true)
    }

    @Test func bootstrapConfiguresPlaidBackendTokenWithoutExposingPlaidSecrets() async {
        let plaidClient = RecordedPlaidClient()
        let container = AppContainerController(
            secretStore: InMemorySecretStore(seed: [.plaidBackendBearerToken: "backend-token"]),
            biometricGate: ScriptableBiometricGate(isAvailable: false),
            plaidClient: plaidClient,
            modelContainer: try! ModelContainerFactory.makeContainer(inMemory: true)
        )

        await container.bootstrap()

        let configuredToken = await plaidClient.configuredBearerToken
        #expect(container.hasPlaidBackendToken)
        #expect(configuredToken == "backend-token")
    }

    @Test func claudeDataSyncUploadsOnlyConfirmedFinancialRowsAndRevokes() async throws {
        let modelContainer = try ModelContainerFactory.makeContainer(
            inMemory: true
        )
        let context = modelContainer.mainContext
        let settings = DurableUserSettings()
        settings.primaryFinancialDataSource = .plaid
        context.insert(settings)
        context.insert(CachedFinancialAccount(
            canonicalAccountId: "private-canonical-account-id",
            externalId: "private-provider-account-id",
            itemId: "private-item-id",
            source: .plaid,
            institutionName: "Example Bank",
            name: "Checking",
            officialName: nil,
            mask: "1234",
            type: .checking,
            subtype: "checking",
            currentBalanceMilliunits: 1_000_000,
            availableBalanceMilliunits: 900_000,
            creditLimitMilliunits: nil,
            isoCurrencyCode: "USD"
        ))
        context.insert(DurableAccountNickname(
            plaidAccountId: "private-provider-account-id",
            nickname: "Household Checking"
        ))
        let confirmed = FinancialTransactionSummary(
            id: "plaid:confirmed",
            externalId: "confirmed",
            source: .plaid,
            accountId: "private-canonical-account-id",
            postedDate: .now,
            authorizedDate: nil,
            amount: Money(milliunits: -25_000),
            pending: false,
            pendingTransactionId: nil,
            rawDescription: "PRIVATE RAW DESCRIPTION",
            originalDescription: nil,
            providerMerchantName: "Market",
            merchantEntityId: "private-merchant-id",
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
        context.insert(CachedFinancialTransaction(
            summary: confirmed,
            classification: TransactionClassification(
                displayName: "Market",
                categoryName: "Groceries",
                treatment: .ordinarySpending,
                confidence: .high,
                provenance: .user,
                requiresReview: false
            ),
            requiresNameReview: false
        ))
        context.insert(CachedFinancialTransaction(
            summary: FinancialTransactionSummary(
                id: "plaid:unreviewed",
                externalId: "unreviewed",
                source: .plaid,
                accountId: "private-canonical-account-id",
                postedDate: .now,
                authorizedDate: nil,
                amount: Money(milliunits: -50_000),
                pending: false,
                pendingTransactionId: nil,
                rawDescription: "UNREVIEWED DESCRIPTION",
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
            ),
            classification: TransactionClassification(
                displayName: "Unknown",
                treatment: .ordinarySpending,
                confidence: .low,
                provenance: .plaidEnrichment,
                requiresReview: true
            ),
            requiresNameReview: true
        ))
        context.insert(DurableNetWorthSnapshot(
            assetsMilliunits: 2_000_000,
            liabilitiesMilliunits: 500_000
        ))
        try context.save()

        let plaidClient = RecordedPlaidClient()
        let container = AppContainerController(
            secretStore: InMemorySecretStore(),
            biometricGate: ScriptableBiometricGate(
                isAvailable: false
            ),
            plaidClient: plaidClient,
            modelContainer: modelContainer
        )

        try await container.setClaudeDataSyncEnabled(true)

        let uploaded = await plaidClient.uploadedClaudeSnapshots
        let snapshot = try #require(uploaded.last)
        #expect(snapshot.accounts.count == 1)
        #expect(snapshot.accounts[0].name == "Household Checking")
        #expect(snapshot.transactions.count == 1)
        #expect(snapshot.transactions[0].contactName == "Market")
        #expect(settings.claudeDataSyncEnabled)
        #expect(settings.claudeDataLastSyncedAt != nil)

        try await container.setClaudeDataSyncEnabled(false)

        #expect(await plaidClient.claudeAccessRevoked)
        #expect(settings.claudeDataSyncEnabled == false)
        #expect(settings.claudeDataLastSyncedAt == nil)
    }

    @Test func accountDisplayNameUsesNewestDurableNickname() {
        let providerAccount = CachedPlaidAccount(
            id: "plaid-account",
            itemId: "item",
            institutionName: "Bank",
            name: "Imported Name"
        )
        let old = DurableAccountNickname(
            plaidAccountId: providerAccount.id,
            nickname: "Old Name",
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let newest = DurableAccountNickname(
            plaidAccountId: providerAccount.id,
            nickname: "Travel Account",
            updatedAt: Date(timeIntervalSince1970: 2)
        )

        let resolver = AccountDisplayNameResolver(
            nicknames: [newest, old]
        )

        #expect(resolver.name(for: providerAccount) == "Travel Account")
        #expect(providerAccount.name == "Imported Name")
    }

    @Test func spendingAccountPinsResolveNewestRowsInDisplayOrder() {
        let rows = (1...5).map { index in
            DurableSpendingAccountPin(
                canonicalAccountId: "account-\(index)",
                isVisible: true,
                displayOrder: index,
                updatedAt: Date(timeIntervalSince1970: Double(index))
            )
        }
        let newestFirstAccount = DurableSpendingAccountPin(
            canonicalAccountId: "account-1",
            isVisible: false,
            displayOrder: 1,
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let resolver = SpendingAccountPinResolver(
            rows: rows + [newestFirstAccount]
        )

        #expect(!resolver.isVisible("account-1"))
        #expect(resolver.visibleAccountIDs(
            availableAccountIDs: Set((1...5).map { "account-\($0)" })
        ) == ["account-2", "account-3", "account-4", "account-5"])
        #expect(
            SpendingAccountPinResolver.maximumVisibleAccounts == 4
        )
    }

    @Test func spendingAccountPinPersistsInDurableSchema() throws {
        let modelContainer = try ModelContainerFactory.makeContainer(
            inMemory: true
        )
        let context = modelContainer.mainContext
        context.insert(DurableSpendingAccountPin(
            canonicalAccountId: "checking",
            isVisible: true,
            displayOrder: 2
        ))
        try context.save()

        let saved = try #require(context.fetch(
            FetchDescriptor<DurableSpendingAccountPin>()
        ).first)
        #expect(saved.canonicalAccountId == "checking")
        #expect(saved.isVisible)
        #expect(saved.displayOrder == 2)
    }

    @Test func accountWarningUsesTheProjectedLowPointAmountAndDate() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let firstBreachDate = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 1,
            day: 15,
            hour: 12
        )))
        let lowPointDate = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 1,
            day: 20,
            hour: 12
        )))
        let firstBreach = CashPositionPoint(
            date: firstBreachDate,
            balance: Money.dollars(-62)
        )
        let lowPoint = CashPositionPoint(
            date: lowPointDate,
            balance: Money.dollars(-125)
        )
        let account = CashAccountProjection(
            accountId: "checking",
            accountName: "Bills Checking",
            startingBalance: Money.dollars(1_000),
            points: [firstBreach, lowPoint],
            lowPoint: lowPoint,
            firstShortfallPoint: firstBreach,
            projectedShortfallLowPoint: lowPoint,
            lowPointEvent: nil,
            fundsCardPayments: false
        )

        #expect(
            ProjectionAccountWarningCopy.title(for: account)
                == "Bills Checking may be overdrawn"
        )
        #expect(
            ProjectionAccountWarningCopy.message(for: account)
                == "Projected to fall $125 below $0 on Jan 20."
        )
    }

    @Test func bootstrapRunsPendingHistoricalReconciliationWithoutNetworkSync() async throws {
        let modelContainer = try ModelContainerFactory.makeContainer(
            inMemory: true
        )
        let container = AppContainerController(
            secretStore: InMemorySecretStore(),
            biometricGate: ScriptableBiometricGate(isAvailable: false),
            plaidClient: RecordedPlaidClient(),
            modelContainer: modelContainer
        )
        await container.bootstrap()
        // Seed after bootstrap: the clean start wipes any pre-existing rows.
        let context = modelContainer.mainContext
        context.insert(CachedFinancialAccount(
            canonicalAccountId: "canonical-card",
            externalId: "plaid-card",
            itemId: "bank-item",
            source: .plaid,
            institutionName: "Bank",
            name: "Card",
            officialName: nil,
            mask: "1234",
            type: .creditCard,
            subtype: "credit card",
            currentBalanceMilliunits: 0,
            availableBalanceMilliunits: nil,
            creditLimitMilliunits: nil,
            isoCurrencyCode: "USD"
        ))
        context.insert(DurableCanonicalAccountBinding(
            canonicalAccountId: "canonical-card",
            plaidAccountId: "plaid-card",
            ynabAccountId: nil,
            itemId: "bank-item",
            institutionName: "Bank",
            accountName: "Card",
            accountType: .creditCard,
            reviewed: true
        ))
        let cursor = PlaidTransactionCursor(
            itemId: "bank-item",
            cursor: "cursor",
            updateStatus: "HISTORICAL_UPDATE_COMPLETE",
            historicalReconciliationVersion: 6
        )
        context.insert(cursor)
        try context.save()

        container.plaidTransactionSyncCoordinator.runLocalMigrationsIfNeeded()

        // With no legacy YNAB cache there is nothing to reconcile, so the
        // marker advances to current and transaction review can unlock.
        #expect(cursor.historicalReconciliationVersion
            == PlaidTransactionSyncCoordinator.currentHistoricalReconciliationVersion)
    }

    @Test func plaidSyncCachesHoldingsAndCreatesPendingReview() async throws {
        let item = PlaidItemDTO(
            id: "item-1",
            institutionName: "First Brokerage",
            status: "healthy",
            lastSyncedAt: .now
        )
        let account = PlaidAccountDTO(
            id: "account-1",
            itemId: item.id,
            institutionName: item.institutionName,
            name: "Brokerage",
            officialName: nil,
            mask: "1234",
            subtype: "brokerage",
            currentBalance: 10_000,
            availableBalance: nil,
            isoCurrencyCode: "USD",
            unofficialCurrencyCode: nil
        )
        let holding = PlaidHoldingDTO(
            accountId: account.id,
            securityId: "security-1",
            quantity: 20,
            institutionValue: 9_500,
            costBasis: 8_000,
            asOf: .now
        )
        let response = PlaidHoldingsResponseDTO(
            items: [item],
            accounts: [account],
            securities: [PlaidSecurityDTO(
                id: "security-1",
                name: "Example Fund",
                tickerSymbol: "EXMPL",
                type: "etf",
                closePrice: 475,
                closePriceAsOf: .now,
                isoCurrencyCode: "USD",
                unofficialCurrencyCode: nil
            )],
            holdings: [holding]
        )
        let modelContainer = try ModelContainerFactory.makeContainer(inMemory: true)
        let coordinator = PlaidSyncCoordinator(
            client: RecordedPlaidClient(holdings: response),
            mainContext: modelContainer.mainContext
        )

        await coordinator.syncAll()

        let accounts = try modelContainer.mainContext.fetch(FetchDescriptor<CachedPlaidAccount>())
        let holdings = try modelContainer.mainContext.fetch(FetchDescriptor<CachedPlaidHolding>())
        let treatments = try modelContainer.mainContext.fetch(
            FetchDescriptor<DurablePlaidAccountTreatment>()
        )
        #expect(accounts.first?.currentBalance == Money.dollars(10_000))
        #expect(holdings.first?.institutionValue == Money.dollars(9_500))
        #expect(treatments.first?.plaidAccountId == "account-1")
        #expect(treatments.first?.treatment == .pendingReview)
        #expect(coordinator.phase == .idle)
    }

    @Test func plaidConnectionExchangesPublicTokenThroughBackendAndSyncs() async throws {
        let item = PlaidItemDTO(
            id: "item-1",
            institutionName: "First Brokerage",
            status: "healthy",
            lastSyncedAt: .now
        )
        let account = PlaidAccountDTO(
            id: "account-1",
            itemId: item.id,
            institutionName: item.institutionName,
            name: "Brokerage",
            officialName: nil,
            mask: "1234",
            subtype: "brokerage",
            currentBalance: 10_000,
            availableBalance: nil,
            isoCurrencyCode: "USD",
            unofficialCurrencyCode: nil
        )
        let client = RecordedPlaidClient(
            exchange: .init(item: item),
            holdings: .init(items: [item], accounts: [account], securities: [], holdings: [])
        )
        let container = AppContainerController(
            secretStore: InMemorySecretStore(),
            biometricGate: ScriptableBiometricGate(isAvailable: false),
            plaidClient: client,
            modelContainer: try ModelContainerFactory.makeContainer(inMemory: true)
        )

        let connectedItem = try await container.completePlaidLink(publicToken: "public-token")

        #expect(connectedItem.id == item.id)
        let exchangedTokens = await client.exchangedPublicTokens
        #expect(exchangedTokens == ["public-token"])
        let cachedAccounts = try container.modelContainer.mainContext.fetch(
            FetchDescriptor<CachedPlaidAccount>()
        )
        #expect(cachedAccounts.map(\.id) == [account.id])
    }

    @Test func plaidBalanceContributesOnlyAfterExplicitInclusion() async throws {
        let modelContainer = try ModelContainerFactory.makeContainer(inMemory: true)
        let context = modelContainer.mainContext
        let account = CachedPlaidAccount(
            id: "account-1",
            itemId: "item-1",
            institutionName: "First Brokerage",
            name: "Brokerage",
            currentBalanceMilliunits: Money.dollars(25_000).milliunits,
            isoCurrencyCode: "USD"
        )
        let treatment = DurablePlaidAccountTreatment(plaidAccountId: account.id)
        context.insert(account)
        context.insert(treatment)
        try context.save()
        let scheduler = SnapshotScheduler(mainContext: context)

        #expect(scheduler.computeBreakdown().investments == .zero)
        #expect(PlaidContributionResolver(
            plaidAccounts: [account],
            treatments: [treatment],
            manualAssets: []
        ).standalonePlaidAccounts.isEmpty)

        treatment.treatment = .duplicateYNAB
        try context.save()
        #expect(scheduler.computeBreakdown().investments == Money.dollars(25_000))
        #expect(PlaidContributionResolver(
            plaidAccounts: [account],
            treatments: [treatment],
            manualAssets: []
        ).standalonePlaidAccounts.map(\.id) == [account.id])

        treatment.treatment = .included
        try context.save()
        #expect(scheduler.computeBreakdown().investments == Money.dollars(25_000))
        #expect(PlaidContributionResolver(
            plaidAccounts: [account],
            treatments: [treatment],
            manualAssets: []
        ).standalonePlaidAccounts.map(\.id) == [account.id])
    }

    @Test func groupedReviewIncludesNewPostedTransactions() throws {
        let modelContainer = try ModelContainerFactory.makeContainer(
            inMemory: true
        )
        let context = modelContainer.mainContext
        let summary = try #require(
            PlaidTransactionDTO(
                id: "new-review",
                accountId: "checking-1",
                date: "2026-08-11",
                amount: 24.50,
                name: "MARKET",
                merchantName: "Market"
            ).financialSummary(canonicalAccountId: "canonical-checking")
        )
        context.insert(CachedFinancialTransaction(
            summary: summary,
            classification: TransactionClassification(
                displayName: "Market",
                categoryName: "Groceries",
                treatment: .ordinarySpending,
                confidence: .high,
                provenance: .plaidEnrichment,
                requiresReview: true
            ),
            reviewOriginRaw: "new"
        ))
        try context.save()

        let clusters = HistoricalReviewCluster.pending(in: context)

        #expect(clusters.count == 1)
        #expect(clusters.first?.transactionIDs == [summary.id])
    }

    @Test func groupedReviewExplainsIncompleteSingleTransaction() {
        let cluster = HistoricalReviewCluster(
            id: "incomplete",
            displayName: "Market",
            payeeCanonicalId: nil,
            categoryName: nil,
            categoryCanonicalId: nil,
            treatment: .ordinarySpending,
            transactionIDs: ["plaid:one"],
            totalMilliunits: Money.dollars(-24.50).milliunits
        )

        #expect(cluster.transactionCountText == "1 transaction")
        #expect(!cluster.canApproveAsShown)
        #expect(
            cluster.approvalRequirement
                == "Choose a category to approve."
        )
    }

    @Test func plaidManualMatchReplacesCurrentValueWithoutDoubleCounting() throws {
        let modelContainer = try ModelContainerFactory.makeContainer(inMemory: true)
        let context = modelContainer.mainContext
        let manual = DurableManualAsset(name: "Brokerage", kind: .brokerage)
        let manualValue = DurableManualAssetValue(
            amountMilliunits: Money.dollars(10_000).milliunits,
            asset: manual
        )
        manual.values = [manualValue]
        context.insert(manual)
        context.insert(manualValue)

        let first = CachedPlaidAccount(
            id: "plaid-1",
            itemId: "item-1",
            institutionName: "Brokerage",
            name: "Taxable",
            currentBalanceMilliunits: Money.dollars(6_000).milliunits,
            isoCurrencyCode: "USD"
        )
        let second = CachedPlaidAccount(
            id: "plaid-2",
            itemId: "item-1",
            institutionName: "Brokerage",
            name: "IRA",
            currentBalanceMilliunits: Money.dollars(5_000).milliunits,
            isoCurrencyCode: "USD"
        )
        context.insert(first)
        context.insert(second)
        context.insert(DurablePlaidAccountTreatment(
            plaidAccountId: first.id,
            treatment: .duplicateManualAsset,
            duplicateSourceId: manual.id.uuidString
        ))
        context.insert(DurablePlaidAccountTreatment(
            plaidAccountId: second.id,
            treatment: .duplicateManualAsset,
            duplicateSourceId: manual.id.uuidString
        ))
        try context.save()

        let resolver = PlaidContributionResolver(
            plaidAccounts: [first, second],
            treatments: try context.fetch(FetchDescriptor<DurablePlaidAccountTreatment>()),
            manualAssets: [manual]
        )
        #expect(resolver.effectiveValue(for: manual) == Money.dollars(11_000))
        #expect(resolver.contributingPlaidAccountIDs == Set([first.id, second.id]))

        let breakdown = SnapshotScheduler(mainContext: context).computeBreakdown()
        #expect(breakdown.investments == Money.dollars(11_000))
        #expect(breakdown.netWorth == Money.dollars(11_000))
        #expect(manual.currentValue == Money.dollars(10_000))

        second.currentBalanceMilliunits = nil
        try context.save()
        let fallbackResolver = PlaidContributionResolver(
            plaidAccounts: [first, second],
            treatments: try context.fetch(FetchDescriptor<DurablePlaidAccountTreatment>()),
            manualAssets: [manual]
        )
        #expect(fallbackResolver.effectiveValue(for: manual) == Money.dollars(10_000))
        #expect(fallbackResolver.contributingPlaidAccountIDs.isEmpty)
        #expect(SnapshotScheduler(mainContext: context).computeBreakdown().investments
            == Money.dollars(10_000))
    }

    @Test func plaidBalanceHistoryRecordsDailyValuesAndPreservesAnUnlinkBoundary() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        func day(_ value: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 7, day: value))!
        }

        let modelContainer = try ModelContainerFactory.makeContainer(inMemory: true)
        let context = modelContainer.mainContext
        let manual = DurableManualAsset(name: "Robinhood", kind: .brokerage)
        let manualValue = DurableManualAssetValue(
            recordedAt: day(1),
            amountMilliunits: Money.dollars(10_000).milliunits,
            asset: manual
        )
        manual.values = [manualValue]
        let account = CachedPlaidAccount(
            id: "plaid-history",
            itemId: "item-history",
            institutionName: "Robinhood",
            name: "Brokerage",
            currentBalanceMilliunits: Money.dollars(11_000).milliunits,
            isoCurrencyCode: "USD"
        )
        let treatment = DurablePlaidAccountTreatment(
            plaidAccountId: account.id,
            treatment: .duplicateManualAsset,
            duplicateSourceId: manual.id.uuidString
        )
        context.insert(manual)
        context.insert(manualValue)
        context.insert(account)
        context.insert(treatment)
        try context.save()

        let scheduler = SnapshotScheduler(mainContext: context, calendar: calendar)
        #expect(scheduler.recordPlaidBalancesIfNeeded(now: day(2)))

        account.currentBalanceMilliunits = Money.dollars(12_000).milliunits
        try context.save()
        #expect(scheduler.recordPlaidBalancesIfNeeded(now: day(3)))

        treatment.treatment = .excluded
        try context.save()
        #expect(scheduler.recordPlaidBalancesIfNeeded(now: day(4)))
        #expect(scheduler.recordPlaidBalancesIfNeeded(now: day(4)))

        let rows = try context.fetch(FetchDescriptor<DurablePlaidBalanceSnapshot>())
            .sorted { $0.date < $1.date }
        #expect(rows.count == 3)
        #expect(rows.map(\.active) == [true, true, false])
        #expect(rows.map(\.balance) == [
            Money.dollars(11_000),
            Money.dollars(12_000),
            Money.dollars(12_000)
        ])
        #expect(rows.allSatisfy { $0.matchedManualAssetId == manual.id })
    }

    @Test func plaidMatchKeepsOtherManualAssetClassification() throws {
        let modelContainer = try ModelContainerFactory.makeContainer(inMemory: true)
        let context = modelContainer.mainContext
        let manual = DurableManualAsset(name: "Vanguard Cash", kind: .other)
        let manualValue = DurableManualAssetValue(
            amountMilliunits: Money.dollars(8_000).milliunits,
            asset: manual
        )
        manual.values = [manualValue]
        let plaid = CachedPlaidAccount(
            id: "vanguard-cash",
            itemId: "vanguard-item",
            institutionName: "Vanguard",
            name: "Cash Plus",
            currentBalanceMilliunits: Money.dollars(8_500).milliunits,
            isoCurrencyCode: "USD"
        )
        context.insert(manual)
        context.insert(manualValue)
        context.insert(plaid)
        context.insert(DurablePlaidAccountTreatment(
            plaidAccountId: plaid.id,
            treatment: .duplicateManualAsset,
            duplicateSourceId: manual.id.uuidString
        ))
        try context.save()

        let breakdown = SnapshotScheduler(mainContext: context).computeBreakdown()

        #expect(breakdown.otherAssets == Money.dollars(8_500))
        #expect(breakdown.investments == .zero)
        #expect(breakdown.totalAssets == Money.dollars(8_500))
        #expect(manual.currentValue == Money.dollars(8_000))
    }

    @Test func bootstrapPurgesRetiredCacheAndPreservesDurableDataAndSecret() async throws {
        let modelContainer = try ModelContainerFactory.makeContainer(inMemory: true)
        let ctx = modelContainer.mainContext
        let settings = DurableUserSettings()
        settings.settingsSchemaVersion = 3
        settings.spendingLookbackDays = 60
        settings.freshStartVersion = 0
        ctx.insert(settings)
        ctx.insert(CachedAccount(
            id: "ynab-checking", budgetId: "budget", name: "Checking",
            typeRaw: "checking", balanceMilliunits: 1_000_000,
            clearedMilliunits: 1_000_000, unclearedMilliunits: 0,
            onBudget: true, closed: false, deleted: false
        ))
        let asset = DurableManualAsset(name: "Home", kind: .realEstate)
        ctx.insert(asset)
        ctx.insert(DurableNetWorthSnapshot(
            date: .now, assetsMilliunits: 1_000_000,
            liabilitiesMilliunits: 0, source: .live
        ))
        ctx.insert(DurableSinkingFund(name: "Vacation"))
        try ctx.save()

        let secrets = InMemorySecretStore(seed: [
            .ynabPersonalAccessToken: "ynab-token"
        ])
        let container = AppContainerController(
            secretStore: secrets,
            biometricGate: ScriptableBiometricGate(isAvailable: false),
            modelContainer: modelContainer
        )
        await container.bootstrap()

        #expect(try ctx.fetch(FetchDescriptor<CachedAccount>()).isEmpty)
        #expect(try ctx.fetch(FetchDescriptor<DurableManualAsset>()).count == 1)
        #expect(try ctx.fetch(FetchDescriptor<DurableNetWorthSnapshot>()).count == 1)
        #expect(try ctx.fetch(FetchDescriptor<DurableSinkingFund>()).count == 1)
        let settingsRows = try ctx.fetch(FetchDescriptor<DurableUserSettings>())
        #expect(settingsRows.count == 1)
        let preserved = try #require(settingsRows.first)
        #expect(preserved.freshStartVersion == 0)
        #expect(preserved.spendingLookbackDays == 60)
        #expect(try secrets.load(.ynabPersonalAccessToken) == "ynab-token")
    }

    @Test func forceFullResyncClearsCursorsAndCoverageButNeverSnapshots() async throws {
        let container = AppContainerController.makePreview()
        await container.bootstrap()
        let ctx = container.modelContainer.mainContext
        ctx.insert(PlaidTransactionCursor(itemId: "item-1", cursor: "abc"))
        ctx.insert(PlaidAccountCoverage(
            plaidAccountId: "acct-1", itemId: "item-1",
            earliestImportedDate: .now, latestImportedDate: .now
        ))
        ctx.insert(DurableNetWorthSnapshot(
            date: .now, assetsMilliunits: 5, liabilitiesMilliunits: 0, source: .live
        ))
        try ctx.save()

        await container.forceFullResync()

        // Cursors and coverage rebuild from the full re-import; snapshots are
        // irreplaceable after the clean start and must survive.
        #expect(try ctx.fetch(FetchDescriptor<PlaidTransactionCursor>()).isEmpty)
        #expect(try ctx.fetch(FetchDescriptor<PlaidAccountCoverage>()).isEmpty)
        #expect(try ctx.fetch(FetchDescriptor<DurableNetWorthSnapshot>()).count == 1)
    }


    @Test func projectionSelectionsAndCardSourcePersist() async throws {
        let container = AppContainerController.makePreview()
        let ctx = container.modelContainer.mainContext
        ctx.insert(DurableProjectionCashAccountOverride(accountId: "reserve", included: false))
        ctx.insert(DurableExcludedSpendTransaction(
            transactionId: "one-time", payeeName: "One-time purchase",
            transactionDate: .now, amountMilliunits: 250_000
        ))
        ctx.insert(DurableCardSettings(
            accountId: "visa", statementCycleDay: 15,
            paymentDueDay: 10, paymentAccountId: "checking"
        ))
        try ctx.save()

        let overrides = try ctx.fetch(FetchDescriptor<DurableProjectionCashAccountOverride>())
        let transactionExclusions = try ctx.fetch(FetchDescriptor<DurableExcludedSpendTransaction>())
        let cards = try ctx.fetch(FetchDescriptor<DurableCardSettings>())
        #expect(overrides.first?.accountId == "reserve")
        #expect(overrides.first?.included == false)
        #expect(transactionExclusions.first?.transactionId == "one-time")
        #expect(cards.first?.paymentAccountId == "checking")
    }

    @Test func snapshotWaitsForFirstPlaidSyncThenIsIdempotentForSameDay() async throws {
        let container = AppContainerController.makePreview()
        await container.bootstrap()
        let ctx = container.modelContainer.mainContext
        let asset = DurableManualAsset(name: "Home", kind: .realEstate)
        ctx.insert(asset)
        let entry = DurableManualAssetValue(
            amountMilliunits: Money.dollars(100).milliunits, asset: asset
        )
        ctx.insert(entry)
        asset.values = [entry]
        try ctx.save()

        // No snapshot before the first successful Plaid sync — history day
        // one must reflect a synced position, never pre-sync manual entry.
        #expect(container.snapshotScheduler.recordIfNeeded() == nil)

        let settings = try #require(try ctx.fetch(
            FetchDescriptor<DurableUserSettings>()
        ).first)
        settings.firstPlaidSyncCompletedAt = .now
        try ctx.save()

        let first = container.snapshotScheduler.recordIfNeeded()
        let second = container.snapshotScheduler.recordIfNeeded()
        #expect(first != nil)
        #expect(first?.id == second?.id)
    }

    @Test func breakdownAddsManualAssets() async throws {
        let container = AppContainerController.makePreview()
        await container.bootstrap()
        let ctx = container.modelContainer.mainContext
        let house = DurableManualAsset(name: "Home", kind: .realEstate)
        ctx.insert(house)
        let entry = DurableManualAssetValue(amountMilliunits: Money.dollars(500_000).milliunits, asset: house)
        ctx.insert(entry)
        house.values = [entry]
        try ctx.save()
        let bd = container.snapshotScheduler.computeBreakdown()
        #expect(bd.manualAssets == Money.dollars(500_000))
        #expect(bd.netWorth == Money.dollars(500_000))
    }

    @Test func linkedIBRLoanLoadsLocallyAndContributesToCurrentBreakdown() async throws {
        let snapshot = linkedLoanSnapshot(
            asOf: Date(timeIntervalSince1970: 2_000_000),
            principal: 80_000,
            accruedInterest: 5_000
        )
        let document = SharedIBRLoanDocument(current: snapshot, history: [snapshot])
        let container = AppContainerController(
            secretStore: InMemorySecretStore(),
            biometricGate: ScriptableBiometricGate(isAvailable: false),
            modelContainer: try ModelContainerFactory.makeContainer(inMemory: true),
            ibrLoanStore: InMemoryIBRLoanStore(document: document)
        )

        await container.bootstrap()

        #expect(container.linkedIBRLoanDocument?.current.totalBalance == Money.dollars(85_000))
        let breakdown = container.snapshotScheduler.computeBreakdown(
            linkedIBRLoan: container.linkedIBRLoanDocument?.current
        )
        #expect(breakdown.loans == Money.dollars(85_000))
        #expect(breakdown.netWorth == Money.dollars(-85_000))
    }

    @Test func linkedIBRLoanHistoryCarriesForwardWithoutCloudPersistence() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let firstDate = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        let secondDate = calendar.date(from: DateComponents(year: 2026, month: 2, day: 1))!
        let first = linkedLoanSnapshot(asOf: firstDate, principal: 90_000, accruedInterest: 4_000)
        let second = linkedLoanSnapshot(asOf: secondDate, principal: 89_000, accruedInterest: 4_500)
        let document = SharedIBRLoanDocument(current: second, history: [first, second])

        #expect(
            document.balance(
                on: calendar.date(from: DateComponents(year: 2025, month: 12, day: 31))!,
                calendar: calendar
            ) == .zero
        )

        let rateSnapshot = linkedLoanSnapshot(
            asOf: firstDate,
            principal: 90_000,
            accruedInterest: 4_000,
            weightedInterestRatePercent: 7.75
        )
        let rateDocument = SharedIBRLoanDocument(
            current: rateSnapshot,
            history: [rateSnapshot]
        )
        #expect(
            rateDocument.balance(
                on: calendar.date(from: DateComponents(year: 2025, month: 12, day: 1))!,
                calendar: calendar,
                historyStartDate: calendar.date(
                    from: DateComponents(year: 2025, month: 1, day: 1)
                )
            ) == Money.dollars(93_407.603)
        )
        #expect(
            document.balance(
                on: calendar.date(from: DateComponents(year: 2026, month: 1, day: 15))!,
                calendar: calendar
            ) == Money.dollars(94_000)
        )
        #expect(
            document.balance(
                on: calendar.date(from: DateComponents(year: 2026, month: 2, day: 15))!,
                calendar: calendar
            ) == Money.dollars(93_500)
        )
        #expect(
            document.balance(
                on: calendar.date(from: DateComponents(year: 2025, month: 6, day: 1))!,
                calendar: calendar,
                historyStartDate: calendar.date(
                    from: DateComponents(year: 2025, month: 1, day: 1)
                )
            ) == Money.dollars(94_000)
        )
        #expect(
            document.balance(
                on: calendar.date(from: DateComponents(year: 2024, month: 12, day: 31))!,
                calendar: calendar,
                historyStartDate: calendar.date(
                    from: DateComponents(year: 2025, month: 1, day: 1)
                )
            ) == .zero
        )

        let modelContainer = try ModelContainerFactory.makeContainer(inMemory: true)
        let checking = CachedAccount(
            id: "checking",
            budgetId: "budget",
            name: "Checking",
            typeRaw: "checking",
            balanceMilliunits: Money.dollars(1_000).milliunits,
            clearedMilliunits: Money.dollars(1_000).milliunits,
            unclearedMilliunits: 0,
            onBudget: true,
            closed: false,
            deleted: false
        )
        modelContainer.mainContext.insert(checking)
        let recordingSettings = DurableUserSettings()
        recordingSettings.firstPlaidSyncCompletedAt = secondDate
        modelContainer.mainContext.insert(recordingSettings)
        try modelContainer.mainContext.save()
        let scheduler = SnapshotScheduler(mainContext: modelContainer.mainContext, calendar: calendar)
        let saved = try #require(scheduler.recordIfNeeded(now: secondDate))
        #expect(saved.liabilities == .zero)
    }

    @Test func linkedIBRLoanHistoryStartOverrideStaysLocal() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let snapshotDate = calendar.date(
            from: DateComponents(year: 2026, month: 1, day: 1)
        )!
        let overrideDate = calendar.date(
            from: DateComponents(year: 2025, month: 1, day: 1)
        )!
        let snapshot = linkedLoanSnapshot(
            asOf: snapshotDate,
            principal: 90_000,
            accruedInterest: 4_000
        )
        let historySettings = InMemoryIBRLoanHistorySettingsStore()
        let container = AppContainerController(
            secretStore: InMemorySecretStore(),
            biometricGate: ScriptableBiometricGate(isAvailable: false),
            modelContainer: try ModelContainerFactory.makeContainer(inMemory: true),
            ibrLoanStore: InMemoryIBRLoanStore(
                document: SharedIBRLoanDocument(current: snapshot, history: [snapshot])
            ),
            ibrLoanHistorySettingsStore: historySettings
        )

        await container.bootstrap()
        container.setLinkedIBRLoanHistoryStartDate(overrideDate)

        // The setter normalizes with the device's current calendar, so the
        // stored value is the local start-of-day for the picked date.
        #expect(historySettings.startDate
            == Calendar.current.startOfDay(for: overrideDate))
        #expect(
            container.linkedIBRLoanBalance(
                on: calendar.date(from: DateComponents(year: 2025, month: 6, day: 1))!,
                calendar: calendar
            ) == Money.dollars(94_000)
        )
        #expect(
            try container.modelContainer.mainContext.fetch(
                FetchDescriptor<DurableNetWorthSnapshot>()
            ).isEmpty
        )
    }

    @Test func linkedIBRLoanDefaultsToEarliestPlaidTransaction() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let plaidStart = calendar.date(
            from: DateComponents(year: 2021, month: 7, day: 1)
        )!
        let ibrStart = calendar.date(
            from: DateComponents(year: 2026, month: 6, day: 29)
        )!
        let snapshot = linkedLoanSnapshot(
            asOf: ibrStart,
            principal: 90_000,
            accruedInterest: 4_000,
            weightedInterestRatePercent: 7.75
        )
        let modelContainer = try ModelContainerFactory.makeContainer(inMemory: true)
        let container = AppContainerController(
            secretStore: InMemorySecretStore(),
            biometricGate: ScriptableBiometricGate(isAvailable: false),
            modelContainer: modelContainer,
            ibrLoanStore: InMemoryIBRLoanStore(
                document: SharedIBRLoanDocument(current: snapshot, history: [snapshot])
            ),
            ibrLoanHistorySettingsStore: InMemoryIBRLoanHistorySettingsStore()
        )
        await container.bootstrap()
        let summary = try #require(PlaidTransactionDTO(
            id: "starting-balance",
            accountId: "checking",
            date: "2021-07-01",
            amount: -1_000,
            name: "Starting Balance"
        ).financialSummary(canonicalAccountId: "checking"))
        modelContainer.mainContext.insert(CachedFinancialTransaction(
            summary: summary,
            classification: TransactionClassification(
                displayName: "Starting Balance",
                categoryName: nil,
                treatment: .income,
                confidence: .high,
                provenance: .user,
                requiresReview: false
            )
        ))
        try modelContainer.mainContext.save()

        #expect(
            container.defaultLinkedIBRLoanHistoryStartDate(calendar: calendar) == plaidStart
        )
        #expect(
            container.linkedIBRLoanBalance(on: plaidStart, calendar: calendar)
                == Money.dollars(90_000)
        )
    }

    // MARK: - Plaid Transactions migration

    @Test func plaidTransactionSyncPersistsNormalizedRowsAndHistoricalStatus() async throws {
        let item = PlaidItemDTO(
            id: "bank-item",
            institutionName: "Example Bank",
            status: "healthy",
            lastSyncedAt: .now,
            products: ["transactions"]
        )
        let account = PlaidAccountDTO(
            id: "checking-1",
            itemId: item.id,
            institutionName: item.institutionName,
            name: "Checking",
            officialName: nil,
            mask: "1234",
            type: "depository",
            subtype: "checking",
            currentBalance: 2_500,
            availableBalance: 2_400,
            isoCurrencyCode: "USD",
            unofficialCurrencyCode: nil
        )
        let transaction = PlaidTransactionDTO(
            id: "transaction-1",
            accountId: account.id,
            date: "2026-07-24",
            amount: 42.50,
            name: "SQ *CAFE",
            merchantName: "Cafe",
            categoryPrimary: "FOOD_AND_DRINK",
            categoryDetailed: "FOOD_AND_DRINK_RESTAURANTS",
            categoryConfidence: "HIGH"
        )
        let response = PlaidTransactionsSyncResponseDTO(
            item: item,
            accounts: [account],
            added: [transaction],
            modified: [],
            removed: [],
            nextCursor: "cursor-1",
            hasMore: false,
            updateStatus: "HISTORICAL_UPDATE_COMPLETE"
        )
        let client = RecordedPlaidClient(
            items: .init(items: [item]),
            transactions: response
        )
        let modelContainer = try ModelContainerFactory.makeContainer(inMemory: true)
        modelContainer.mainContext.insert(DurableUserSettings())
        let coordinator = PlaidTransactionSyncCoordinator(
            client: client,
            inferenceProvider: RecordedTransactionInferenceProvider(),
            mainContext: modelContainer.mainContext
        )

        let syncSucceeded = await coordinator.syncAll()
        #expect(syncSucceeded)

        let accounts = try modelContainer.mainContext.fetch(
            FetchDescriptor<CachedFinancialAccount>()
        )
        let transactions = try modelContainer.mainContext.fetch(
            FetchDescriptor<CachedFinancialTransaction>()
        )
        let cursors = try modelContainer.mainContext.fetch(
            FetchDescriptor<PlaidTransactionCursor>()
        )
        #expect(accounts.first?.balance == Money.dollars(2_500))
        #expect(transactions.first?.amountMilliunits == Money.dollars(-42.50).milliunits)
        #expect(transactions.first?.requiresReview == true)
        #expect(transactions.first?.requiresNameReview == true)
        #expect(transactions.first?.categoryName == nil)
        #expect(transactions.first?.reviewOriginRaw == "historical")
        #expect(transactions.first?.toProjectionSummary() == nil)
        #expect(cursors.first?.historicalImportComplete == true)
    }

    @Test func newPostedTransactionsRequireReviewButPendingDoNot() async throws {
        let item = PlaidItemDTO(
            id: "bank-item",
            institutionName: "Example Bank",
            status: "healthy",
            lastSyncedAt: .now,
            products: ["transactions"]
        )
        let account = PlaidAccountDTO(
            id: "checking-1",
            itemId: item.id,
            institutionName: item.institutionName,
            name: "Checking",
            officialName: nil,
            mask: "1234",
            type: "depository",
            subtype: "checking",
            currentBalance: 2_500,
            availableBalance: 2_400,
            isoCurrencyCode: "USD",
            unofficialCurrencyCode: nil
        )
        let posted = PlaidTransactionDTO(
            id: "posted",
            accountId: account.id,
            date: "2026-07-24",
            amount: 20,
            name: "POSTED STORE",
            merchantName: "Posted Store"
        )
        let pending = PlaidTransactionDTO(
            id: "pending",
            accountId: account.id,
            date: "2026-07-25",
            amount: 10,
            pending: true,
            name: "PENDING STORE",
            merchantName: "Pending Store"
        )
        let knownPosted = PlaidTransactionDTO(
            id: "known-posted",
            accountId: account.id,
            date: "2026-07-24",
            amount: 15,
            name: "KNOWN STORE",
            merchantName: "Known Store",
            merchantEntityId: "known-store"
        )
        let client = RecordedPlaidClient(
            items: .init(items: [item]),
            transactions: PlaidTransactionsSyncResponseDTO(
                item: item,
                accounts: [account],
                added: [posted, pending, knownPosted],
                modified: [],
                removed: [],
                nextCursor: "cursor-2",
                hasMore: false,
                updateStatus: "HISTORICAL_UPDATE_COMPLETE"
            )
        )
        let modelContainer = try ModelContainerFactory.makeContainer(
            inMemory: true
        )
        let context = modelContainer.mainContext
        context.insert(DurableUserSettings())
        context.insert(PlaidTransactionCursor(
            itemId: item.id,
            cursor: "cursor-1",
            updateStatus: "HISTORICAL_UPDATE_COMPLETE",
            historicalReconciliationVersion:
                PlaidTransactionSyncCoordinator.currentHistoricalReconciliationVersion
        ))
        let historicalKnownSummary = try #require(
            PlaidTransactionDTO(
                id: "historical-known",
                accountId: account.id,
                date: "2026-06-24",
                amount: 12,
                name: "KNOWN STORE",
                merchantName: "Known Store",
                merchantEntityId: "known-store"
            ).financialSummary(canonicalAccountId: "historical-account")
        )
        context.insert(CachedFinancialTransaction(
            summary: historicalKnownSummary,
            classification: TransactionClassifier().classify(
                historicalKnownSummary,
                rules: []
            ),
            requiresNameReview: false,
            reviewOriginRaw: "historical"
        ))
        try context.save()
        let coordinator = PlaidTransactionSyncCoordinator(
            client: client,
            inferenceProvider: RecordedTransactionInferenceProvider(),
            mainContext: context
        )

        #expect(await coordinator.syncAll())

        let rows = try context.fetch(
            FetchDescriptor<CachedFinancialTransaction>()
        )
        let postedRow = try #require(rows.first { $0.externalId == "posted" })
        let pendingRow = try #require(rows.first { $0.externalId == "pending" })
        let knownPostedRow = try #require(
            rows.first { $0.externalId == "known-posted" }
        )
        #expect(postedRow.reviewOriginRaw == "new")
        #expect(postedRow.requiresReview)
        #expect(postedRow.requiresNameReview)
        #expect(postedRow.toProjectionSummary() == nil)
        #expect(pendingRow.reviewOriginRaw == "new")
        #expect(!pendingRow.requiresReview)
        #expect(!pendingRow.requiresNameReview)
        #expect(pendingRow.toProjectionSummary() == nil)
        #expect(knownPostedRow.requiresReview)
        // Canonical semantics: a merchant is "known" only through a confirmed
        // payee alias. No alias exists here, so even a repeat merchant still
        // needs name review (the legacy fingerprint shortcut was removed).
        #expect(knownPostedRow.requiresNameReview)
    }

    @Test func accountHistoryFetchesOnlyOneOrderedPage() throws {
        let modelContainer = try ModelContainerFactory.makeContainer(
            inMemory: true
        )
        let context = modelContainer.mainContext
        let classification = TransactionClassification(
            displayName: "Transaction",
            categoryName: "Reviewed Category",
            treatment: .ordinarySpending,
            confidence: .high,
            provenance: .user,
            requiresReview: false
        )

        for index in 0..<120 {
            let summary = FinancialTransactionSummary(
                id: "plaid:page-\(index)",
                externalId: "page-\(index)",
                source: .plaid,
                accountId: "paged-account",
                postedDate: Date(
                    timeIntervalSinceReferenceDate: Double(index * 86_400)
                ),
                authorizedDate: nil,
                amount: Money.dollars(-1),
                pending: false,
                pendingTransactionId: nil,
                rawDescription: "Transaction \(index)",
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
            context.insert(CachedFinancialTransaction(
                summary: summary,
                classification: classification
            ))
        }
        let otherAccount = FinancialTransactionSummary(
            id: "plaid:other-account",
            externalId: "other-account",
            source: .plaid,
            accountId: "other-account",
            postedDate: .distantFuture,
            authorizedDate: nil,
            amount: Money.dollars(-1),
            pending: false,
            pendingTransactionId: nil,
            rawDescription: "Other",
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
        context.insert(CachedFinancialTransaction(
            summary: otherAccount,
            classification: classification
        ))
        try context.save()

        let first = try FinancialTransactionPageFetcher.fetch(
            accountID: "paged-account",
            offset: 0,
            limit: 50,
            context: context
        )
        let second = try FinancialTransactionPageFetcher.fetch(
            accountID: "paged-account",
            offset: 50,
            limit: 50,
            context: context
        )

        #expect(first.count == 50)
        #expect(second.count == 50)
        #expect(first.allSatisfy { $0.canonicalAccountId == "paged-account" })
        #expect(Set(first.map(\.id)).isDisjoint(with: Set(second.map(\.id))))
        #expect(first.first?.externalId == "page-119")
        #expect(second.first?.externalId == "page-69")
    }

    @Test func categoryHistoryIncludesReviewedWholeAndSplitTransactions() throws {
        let modelContainer = try ModelContainerFactory.makeContainer(
            inMemory: true
        )
        let context = modelContainer.mainContext
        let categoryID = "networth:groceries"

        func transaction(
            id: String,
            name: String,
            amount: Money,
            requiresReview: Bool,
            splits: [SubTransactionSummary] = []
        ) throws -> CachedFinancialTransaction {
            let summary = FinancialTransactionSummary(
                id: id,
                externalId: id,
                source: .plaid,
                accountId: "checking",
                postedDate: Date(
                    timeIntervalSinceReferenceDate:
                        id == "whole" ? 200_000 : 100_000
                ),
                authorizedDate: nil,
                amount: amount,
                pending: false,
                pendingTransactionId: nil,
                rawDescription: name,
                originalDescription: nil,
                providerMerchantName: name,
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
            let row = CachedFinancialTransaction(
                summary: summary,
                classification: TransactionClassification(
                    displayName: name,
                    categoryName: splits.isEmpty ? "Groceries" : nil,
                    treatment: .ordinarySpending,
                    confidence: .high,
                    provenance: .user,
                    requiresReview: requiresReview
                ),
                subtransactionsData: splits.isEmpty
                    ? nil
                    : try JSONEncoder().encode(splits),
                requiresNameReview: false
            )
            if splits.isEmpty {
                row.categoryCanonicalId = categoryID
            }
            return row
        }

        let splitLegs = [
            SubTransactionSummary(
                id: "split-groceries",
                amount: Money.dollars(-60),
                categoryId: nil,
                categoryName: "Groceries",
                categoryCanonicalId: categoryID,
                forecastTreatment: .ordinarySpending,
                payeeName: nil,
                memo: nil,
                deleted: false
            ),
            SubTransactionSummary(
                id: "split-household",
                amount: Money.dollars(-40),
                categoryId: nil,
                categoryName: "Household",
                categoryCanonicalId: "networth:household",
                forecastTreatment: .ordinarySpending,
                payeeName: nil,
                memo: nil,
                deleted: false
            )
        ]
        context.insert(try transaction(
            id: "whole",
            name: "Market",
            amount: Money.dollars(-25),
            requiresReview: false
        ))
        context.insert(try transaction(
            id: "split",
            name: "Big Store",
            amount: Money.dollars(-100),
            requiresReview: false,
            splits: splitLegs
        ))
        context.insert(try transaction(
            id: "unreviewed",
            name: "Suggested Market",
            amount: Money.dollars(-15),
            requiresReview: true
        ))
        try context.save()

        let filter = FinancialTransactionCategoryFilter(
            key: categoryID,
            name: "Groceries"
        )
        let rows = try FinancialTransactionPageFetcher.fetch(
            accountID: nil,
            offset: 0,
            categoryFilter: filter,
            context: context
        )
        let split = try #require(rows.first { $0.id == "split" })

        #expect(rows.map(\.id) == ["whole", "split"])
        #expect(filter.matchingAmountMilliunits(in: split)
            == Money.dollars(-60).milliunits)
    }

    @Test func plaidHistoricalReconciliationRunsOnceAfterImport() async throws {
        let item = PlaidItemDTO(
            id: "bank-item",
            institutionName: "Example Bank",
            status: "healthy",
            lastSyncedAt: .now,
            products: ["transactions"]
        )
        let account = PlaidAccountDTO(
            id: "checking-1",
            itemId: item.id,
            institutionName: item.institutionName,
            name: "Checking",
            officialName: nil,
            mask: "1234",
            type: "depository",
            subtype: "checking",
            currentBalance: 2_500,
            availableBalance: 2_400,
            isoCurrencyCode: "USD",
            unofficialCurrencyCode: nil
        )
        let response = PlaidTransactionsSyncResponseDTO(
            item: item,
            accounts: [account],
            added: [],
            modified: [],
            removed: [],
            nextCursor: "cursor-2",
            hasMore: false,
            updateStatus: "HISTORICAL_UPDATE_COMPLETE"
        )
        let client = RecordedPlaidClient(
            items: .init(items: [item]),
            transactions: response
        )
        let modelContainer = try ModelContainerFactory.makeContainer(inMemory: true)
        let context = modelContainer.mainContext
        context.insert(DurableUserSettings())
        context.insert(
            DurableCanonicalAccountBinding(
                canonicalAccountId: "canonical-checking",
                plaidAccountId: account.id,
                ynabAccountId: nil,
                itemId: item.id,
                institutionName: item.institutionName,
                accountName: account.name,
                accountType: .checking,
                reviewed: true
            )
        )
        context.insert(
            PlaidTransactionCursor(
                itemId: item.id,
                cursor: "cursor-1",
                updateStatus: "HISTORICAL_UPDATE_COMPLETE"
            )
        )
        try context.save()
        let coordinator = PlaidTransactionSyncCoordinator(
            client: client,
            inferenceProvider: RecordedTransactionInferenceProvider(),
            mainContext: context
        )

        let firstSyncSucceeded = await coordinator.syncAll()
        #expect(firstSyncSucceeded)
        let cursor = try #require(
            try context.fetch(FetchDescriptor<PlaidTransactionCursor>()).first
        )
        #expect(cursor.historicalReconciliationVersion
            == PlaidTransactionSyncCoordinator.currentHistoricalReconciliationVersion)

        context.insert(
            LegacyTransactionMatchRow(
                plaidTransactionId: "sentinel-plaid",
                ynabTransactionId: "sentinel-ynab",
                confidence: .high,
                score: 9,
                automatic: true
            )
        )
        try context.save()

        let secondSyncSucceeded = await coordinator.syncAll()
        #expect(secondSyncSucceeded)
        let matches = try context.fetch(
            FetchDescriptor<LegacyTransactionMatchRow>()
        )
        #expect(matches.map(\.plaidTransactionId) == ["sentinel-plaid"])
        #expect(cursor.historicalReconciliationVersion
            == PlaidTransactionSyncCoordinator.currentHistoricalReconciliationVersion)
    }

    @Test func canonicalConfirmationsLearnIdentityWithoutCreatingCategoryRules()
        throws {
        // Retain the container for the test's lifetime: grabbing only
        // `.mainContext` leaves the container to autorelease timing, and a
        // deallocated store makes the first insert hang forever.
        let modelContainer = try ModelContainerFactory.makeContainer(
            inMemory: true
        )
        let context = modelContainer.mainContext
        let payee = DurableCanonicalPayee(
            canonicalId: "ynab:payee-store",
            ynabPayeeId: "payee-store",
            name: "Example Store",
            sourceName: "Example Store"
        )
        let groceries = DurableCanonicalCategory(
            canonicalId: "ynab:category-groceries",
            ynabCategoryId: "category-groceries",
            name: "Groceries",
            groupName: "Everyday",
            sourceName: "Groceries",
            sourceGroupName: "Everyday"
        )
        let household = DurableCanonicalCategory(
            canonicalId: "ynab:category-household",
            ynabCategoryId: "category-household",
            name: "Household",
            groupName: "Everyday",
            sourceName: "Household",
            sourceGroupName: "Everyday"
        )
        context.insert(payee)
        context.insert(groceries)
        context.insert(household)

        func transaction(_ id: String, day: Int) throws
            -> CachedFinancialTransaction {
            let summary = try #require(
                PlaidTransactionDTO(
                    id: id,
                    accountId: "card-1",
                    date: "2026-07-\(day)",
                    amount: 25,
                    name: "EXAMPLE STORE 1234",
                    merchantName: "Example Store",
                    merchantEntityId: "merchant-example-store"
                ).financialSummary(canonicalAccountId: "canonical-card")
            )
            return CachedFinancialTransaction(
                summary: summary,
                classification: TransactionClassifier().classify(
                    summary,
                    rules: []
                ),
                requiresNameReview: true
            )
        }

        let first = try transaction("canonical-first", day: 24)
        let second = try transaction("canonical-second", day: 23)
        let future = try transaction("canonical-future", day: 22)
        context.insert(first)
        context.insert(second)
        context.insert(future)
        try context.save()

        let coordinator = PlaidTransactionSyncCoordinator(
            client: RecordedPlaidClient(),
            inferenceProvider: RecordedTransactionInferenceProvider(),
            mainContext: context
        )
        #expect(coordinator.confirmTransaction(
            id: first.id,
            displayName: payee.name,
            categoryName: groceries.name,
            treatment: .ordinarySpending,
            categoryCanonicalId: groceries.canonicalId
        ))
        #expect(coordinator.confirmTransaction(
            id: second.id,
            displayName: payee.name,
            categoryName: household.name,
            treatment: .ordinarySpending,
            categoryCanonicalId: household.canonicalId
        ))

        let decisions = try context.fetch(
            FetchDescriptor<DurableCanonicalTransactionDecision>()
        )
        let aliases = try context.fetch(
            FetchDescriptor<DurablePayeeAlias>()
        )
        #expect(decisions.count == 2)
        #expect(decisions.allSatisfy { $0.amountSign == -1 })
        #expect(!aliases.isEmpty)
        #expect(
            aliases.allSatisfy {
                $0.payeeCanonicalId == payee.canonicalId
                    && $0.confirmed
            }
        )
        #expect(future.payeeCanonicalId == payee.canonicalId)
        #expect(future.categoryCanonicalId == nil)
        #expect(future.requiresReview)
        #expect(
            try context.fetch(
                FetchDescriptor<DurableMerchantRule>()
            ).isEmpty
        )
        #expect(
            try context.fetch(
                FetchDescriptor<DurableTransactionOverride>()
            ).isEmpty
        )
    }

    @Test(.disabled("Replaced by canonical transaction decision coverage"))
    func confirmingPostedTransactionPersistsAndEnablesProjection() throws {
        let summary = try #require(
            PlaidTransactionDTO(
                id: "posted-review",
                accountId: "card-1",
                date: "2026-07-24",
                amount: 42.50,
                name: "STORE 1234",
                merchantName: "Store",
                merchantEntityId: "merchant-store"
            ).financialSummary(canonicalAccountId: "canonical-card")
        )
        let modelContainer = try ModelContainerFactory.makeContainer(
            inMemory: true
        )
        let context = modelContainer.mainContext
        context.insert(DurableTransactionCategory(name: "Home Supplies"))
        context.insert(CachedFinancialTransaction(
            summary: summary,
            classification: TransactionClassification(
                displayName: "Store",
                categoryName: "Shopping",
                treatment: .ordinarySpending,
                confidence: .high,
                provenance: .confirmedRule,
                requiresReview: true
            ),
            reviewOriginRaw: "new"
        ))
        try context.save()
        let coordinator = PlaidTransactionSyncCoordinator(
            client: RecordedPlaidClient(),
            inferenceProvider: RecordedTransactionInferenceProvider(),
            mainContext: context
        )

        let saved = coordinator.confirmTransaction(
            id: summary.id,
            displayName: "Store",
            categoryName: "Home Supplies",
            treatment: .ordinarySpending
        )

        let row = try #require(
            context.fetch(FetchDescriptor<CachedFinancialTransaction>()).first
        )
        let rule = try #require(
            context.fetch(FetchDescriptor<DurableMerchantRule>()).first
        )
        let override = try #require(
            context.fetch(FetchDescriptor<DurableTransactionOverride>()).first
        )
        #expect(saved)
        #expect(!row.requiresReview)
        #expect(row.categoryDisplayName == "Home Supplies")
        #expect(row.toProjectionSummary() != nil)
        #expect(rule.categoryName == "Home Supplies")
        #expect(rule.categoryReusable)
        #expect(override.categoryName == "Home Supplies")
    }

    @Test(.disabled("Replaced by canonical transaction decision coverage"))
    func cardPaymentConfirmationNeedsNoCategory() throws {
        let summary = try #require(
            PlaidTransactionDTO(
                id: "card-payment-review",
                accountId: "card-1",
                date: "2026-07-24",
                amount: -500,
                name: "AUTOMATIC PAYMENT",
                merchantName: "Chase"
            ).financialSummary(canonicalAccountId: "canonical-card")
        )
        let modelContainer = try ModelContainerFactory.makeContainer(
            inMemory: true
        )
        let context = modelContainer.mainContext
        context.insert(CachedFinancialTransaction(
            summary: summary,
            classification: TransactionClassification(
                displayName: "Chase Credit Card Payment",
                categoryName: "Income",
                treatment: .cardPayment,
                confidence: .medium,
                provenance: .plaidEnrichment,
                requiresReview: true
            ),
            reviewOriginRaw: "new"
        ))
        try context.save()
        let coordinator = PlaidTransactionSyncCoordinator(
            client: RecordedPlaidClient(),
            inferenceProvider: RecordedTransactionInferenceProvider(),
            mainContext: context
        )

        let saved = coordinator.confirmTransaction(
            id: summary.id,
            displayName: "Chase Credit Card Payment",
            categoryName: nil,
            treatment: .cardPayment
        )

        let row = try #require(
            context.fetch(FetchDescriptor<CachedFinancialTransaction>()).first
        )
        let override = try #require(
            context.fetch(FetchDescriptor<DurableTransactionOverride>()).first
        )
        #expect(saved)
        #expect(!row.requiresReview)
        #expect(row.categoryName == nil)
        #expect(row.forecastTreatment == .cardPayment)
        #expect(row.toProjectionSummary() == nil)
        #expect(override.categoryName == nil)
    }

    @Test(.disabled("Legacy merchant-rule behavior was removed"))
    func confirmedContactAliasLeavesNameQueueDuringMigration() throws {
        let summary = try #require(
            PlaidTransactionDTO(
                id: "gusto-new-fingerprint",
                accountId: "checking-1",
                date: "2026-07-24",
                amount: -2_000,
                name: "GUSTO PAY 3819",
                merchantEntityId: "gusto-new-entity"
            ).financialSummary(canonicalAccountId: "canonical-checking")
        )
        let modelContainer = try ModelContainerFactory.makeContainer(
            inMemory: true
        )
        let context = modelContainer.mainContext
        context.insert(DurableMerchantRule(
            fingerprint: "merchant:gusto-existing",
            preferredName: "Gusto Payroll",
            categoryName: "Income",
            forecastTreatment: .income,
            categoryReusable: false,
            ruleSchemaVersion: 3,
            provenance: .user,
            confirmed: true,
            nameConfirmedAt: .now
        ))
        context.insert(CachedFinancialTransaction(
            summary: summary,
            classification: TransactionClassification(
                displayName: "Gusto Pay",
                categoryName: "Income",
                treatment: .income,
                confidence: .low,
                provenance: .plaidEnrichment,
                requiresReview: true
            ),
            requiresNameReview: true
        ))
        try context.save()
        let coordinator = PlaidTransactionSyncCoordinator(
            client: RecordedPlaidClient(),
            inferenceProvider: RecordedTransactionInferenceProvider(),
            mainContext: context
        )

        coordinator.runLocalMigrationsIfNeeded()

        let row = try #require(
            context.fetch(FetchDescriptor<CachedFinancialTransaction>()).first
        )
        let rule = try #require(
            context.fetch(FetchDescriptor<DurableMerchantRule>()).first
        )
        #expect(row.displayName == "Gusto Payroll")
        #expect(!row.requiresNameReview)
        #expect(rule.ruleSchemaVersion == 4)
    }

    @Test(.disabled("Legacy merchant-rule behavior was removed"))
    func plaidReviewPreservesCustomCategoryNameForFutureMatches() throws {
        let dto = PlaidTransactionDTO(
            id: "transaction-1",
            accountId: "card-1",
            date: "2026-07-24",
            amount: 42.50,
            name: "MESSY MERCHANT",
            merchantName: "Merchant",
            merchantEntityId: "merchant-1"
        )
        let summary = try #require(
            dto.financialSummary(canonicalAccountId: "canonical-card")
        )
        let matchingSummary = try #require(
            PlaidTransactionDTO(
                id: "transaction-2",
                accountId: "card-1",
                date: "2026-07-23",
                amount: 18.25,
                name: "ANOTHER MESSY DESCRIPTION",
                merchantName: "Merchant",
                merchantEntityId: "merchant-1"
            ).financialSummary(canonicalAccountId: "canonical-card")
        )
        let unrelatedSummary = try #require(
            PlaidTransactionDTO(
                id: "transaction-3",
                accountId: "card-1",
                date: "2026-07-22",
                amount: 12,
                name: "OTHER MERCHANT",
                merchantName: "Other Merchant",
                merchantEntityId: "merchant-2"
            ).financialSummary(canonicalAccountId: "canonical-card")
        )
        let classifier = TransactionClassifier()
        let modelContainer = try ModelContainerFactory.makeContainer(inMemory: true)
        modelContainer.mainContext.insert(CachedCategory(
            id: "work-reimbursements",
            budgetId: "budget",
            groupId: "group",
            groupName: "Work",
            name: "Work Reimbursements"
        ))
        for candidate in [summary, matchingSummary, unrelatedSummary] {
            modelContainer.mainContext.insert(
                CachedFinancialTransaction(
                    summary: candidate,
                    classification: classifier.classify(candidate, rules: [])
                )
            )
        }
        try modelContainer.mainContext.save()
        let coordinator = PlaidTransactionSyncCoordinator(
            client: RecordedPlaidClient(),
            inferenceProvider: RecordedTransactionInferenceProvider(),
            mainContext: modelContainer.mainContext
        )

        let saved = coordinator.confirmTransaction(
            id: summary.id,
            displayName: "Local Merchant",
            categoryName: "Work Reimbursements",
            treatment: .refund
        )

        let transactions = try modelContainer.mainContext.fetch(
            FetchDescriptor<CachedFinancialTransaction>()
        )
        let matchingTransactions = transactions.filter {
            $0.toSummary().merchantFingerprint == summary.merchantFingerprint
        }
        let unrelatedTransaction = try #require(
            transactions.first { $0.id == unrelatedSummary.id }
        )
        let rule = try #require(
            modelContainer.mainContext.fetch(
                FetchDescriptor<DurableMerchantRule>()
            ).first
        )
        #expect(matchingTransactions.count == 2)
        #expect(matchingTransactions.allSatisfy { $0.displayName == "Local Merchant" })
        let reviewed = try #require(
            matchingTransactions.first { $0.id == summary.id }
        )
        let stillPending = try #require(
            matchingTransactions.first { $0.id == matchingSummary.id }
        )
        #expect(saved)
        #expect(reviewed.categoryDisplayName == "Work Reimbursements")
        #expect(!reviewed.requiresReview)
        #expect(stillPending.categoryDisplayName != "Work Reimbursements")
        #expect(stillPending.requiresReview)
        #expect(rule.categoryName == "Work Reimbursements")
        #expect(rule.categoryReusable)
        #expect(unrelatedTransaction.requiresReview)
    }

    @Test(.disabled("Legacy merchant-rule behavior was removed"))
    func plaidReviewReusesNameButNotCategoryForMixedMerchant() throws {
        let first = try #require(
            PlaidTransactionDTO(
                id: "target-grocery",
                accountId: "card-1",
                date: "2026-07-24",
                amount: 42.50,
                name: "TARGET 1234",
                merchantName: "Target",
                merchantEntityId: "merchant-target"
            ).financialSummary(canonicalAccountId: "canonical-card")
        )
        let second = try #require(
            PlaidTransactionDTO(
                id: "target-home",
                accountId: "card-1",
                date: "2026-07-23",
                amount: 18.25,
                name: "TARGET 1234",
                merchantName: "Target",
                merchantEntityId: "merchant-target"
            ).financialSummary(canonicalAccountId: "canonical-card")
        )
        let context = try ModelContainerFactory.makeContainer(
            inMemory: true
        ).mainContext
        context.insert(CachedCategory(
            id: "groceries",
            budgetId: "budget",
            groupId: "group",
            groupName: "Living",
            name: "Groceries"
        ))
        context.insert(CachedCategory(
            id: "home",
            budgetId: "budget",
            groupId: "group",
            groupName: "Living",
            name: "Home Improvement"
        ))
        context.insert(CachedFinancialTransaction(
            summary: first,
            classification: TransactionClassification(
                displayName: "Target",
                categoryName: "Groceries",
                treatment: .ordinarySpending,
                confidence: .low,
                provenance: .plaidEnrichment,
                requiresReview: true
            )
        ))
        context.insert(CachedFinancialTransaction(
            summary: second,
            classification: TransactionClassification(
                displayName: "Target",
                categoryName: "Home Improvement",
                treatment: .ordinarySpending,
                confidence: .low,
                provenance: .plaidEnrichment,
                requiresReview: true
            )
        ))
        try context.save()
        let coordinator = PlaidTransactionSyncCoordinator(
            client: RecordedPlaidClient(),
            inferenceProvider: RecordedTransactionInferenceProvider(),
            mainContext: context
        )

        let saved = coordinator.confirmTransaction(
            id: first.id,
            displayName: "Target",
            categoryName: "Groceries",
            treatment: .ordinarySpending
        )

        let rows = try context.fetch(
            FetchDescriptor<CachedFinancialTransaction>()
        )
        let reviewed = try #require(rows.first { $0.id == first.id })
        let stillPending = try #require(rows.first { $0.id == second.id })
        let rule = try #require(
            context.fetch(FetchDescriptor<DurableMerchantRule>()).first
        )
        #expect(saved)
        #expect(reviewed.categoryDisplayName == "Groceries")
        #expect(!reviewed.requiresReview)
        #expect(stillPending.categoryDisplayName == "Home Improvement")
        #expect(stillPending.requiresReview)
        #expect(rows.allSatisfy { $0.displayName == "Target" })
        #expect(rule.categoryReusable)
    }

    @Test(.disabled("Legacy merchant-rule behavior was removed"))
    func hiddenHistoricalCategoryIsPreservedButNeverReused() throws {
        let summary = try #require(
            PlaidTransactionDTO(
                id: "old-transaction",
                accountId: "card-1",
                date: "2024-07-24",
                amount: 10,
                name: "OLD MERCHANT",
                merchantName: "Old Merchant",
                merchantEntityId: "old-merchant"
            ).financialSummary(canonicalAccountId: "canonical-card")
        )
        let context = try ModelContainerFactory.makeContainer(
            inMemory: true
        ).mainContext
        context.insert(CachedCategory(
            id: "old-category",
            budgetId: "budget",
            groupId: "old-group",
            groupName: "Old",
            name: "Old Category",
            hidden: true
        ))
        context.insert(CachedFinancialTransaction(
            summary: summary,
            classification: TransactionClassification(
                displayName: "Old Merchant",
                categoryName: "Old Category",
                treatment: .ordinarySpending,
                confidence: .low,
                provenance: .historicalMatch,
                requiresReview: true
            )
        ))
        try context.save()
        let coordinator = PlaidTransactionSyncCoordinator(
            client: RecordedPlaidClient(),
            inferenceProvider: RecordedTransactionInferenceProvider(),
            mainContext: context
        )

        let saved = coordinator.confirmTransaction(
            id: summary.id,
            displayName: "Old Merchant",
            categoryName: "Old Category",
            treatment: .ordinarySpending
        )

        let row = try #require(
            context.fetch(FetchDescriptor<CachedFinancialTransaction>()).first
        )
        let rule = try #require(
            context.fetch(FetchDescriptor<DurableMerchantRule>()).first
        )
        #expect(saved)
        #expect(row.categoryDisplayName == "Old Category")
        #expect(!row.requiresReview)
        #expect(!rule.categoryReusable)
    }

    @Test(.disabled("Legacy merchant-rule behavior was removed"))
    func legacyRuleRemainsSuggestionButReopensTransactionReview() async throws {
        let summary = try #require(
            PlaidTransactionDTO(
                id: "legacy-rule-transaction",
                accountId: "card-1",
                date: "2026-07-24",
                amount: 10,
                name: "KNOWN MERCHANT",
                merchantName: "Known Merchant",
                merchantEntityId: "known-merchant"
            ).financialSummary(canonicalAccountId: "canonical-card")
        )
        let modelContainer = try ModelContainerFactory.makeContainer(inMemory: true)
        let context = modelContainer.mainContext
        let initial = TransactionClassifier().classify(summary, rules: [])
        context.insert(CachedFinancialTransaction(
            summary: summary,
            classification: initial,
            requiresNameReview: false
        ))
        context.insert(DurableMerchantRule(
            fingerprint: summary.merchantFingerprint,
            preferredName: "Known Merchant",
            categoryName: "Shopping",
            forecastTreatment: .ordinarySpending,
            categoryReusable: false,
            ruleSchemaVersion: 0,
            provenance: .user,
            confirmed: true
        ))
        try context.save()
        let coordinator = PlaidTransactionSyncCoordinator(
            client: RecordedPlaidClient(),
            inferenceProvider: RecordedTransactionInferenceProvider(),
            mainContext: context
        )

        _ = await coordinator.syncAll()

        let rule = try #require(
            context.fetch(FetchDescriptor<DurableMerchantRule>()).first
        )
        let row = try #require(
            context.fetch(FetchDescriptor<CachedFinancialTransaction>()).first
        )
        #expect(rule.ruleSchemaVersion == 2)
        #expect(rule.categoryReusable)
        #expect(rule.nameConfirmedAt != nil)
        #expect(row.requiresReview)
        #expect(!row.requiresNameReview)
    }

    @Test(.disabled("Legacy merchant-rule behavior was removed"))
    func merchantRuleMigrationReusesNameAcrossBankReferenceNumbers() throws {
        let first = try #require(
            PlaidTransactionDTO(
                id: "treasury-1",
                accountId: "checking-1",
                date: "2026-02-09",
                amount: -100,
                name: """
                APA TREAS 310 DES:MISC PAY ID:RSXXXXX00029867 \
                INDN:Botto,Paul CO ID:XXXXX36151 PPD
                """
            ).financialSummary(canonicalAccountId: "canonical-checking")
        )
        let second = try #require(
            PlaidTransactionDTO(
                id: "treasury-2",
                accountId: "checking-1",
                date: "2025-02-03",
                amount: -100,
                name: """
                APA TREAS 310 DES:MISC PAY ID:RSXXXXX00032969 \
                INDN:Botto,Paul CO ID:XXXXX47262 PPD
                """
            ).financialSummary(canonicalAccountId: "canonical-checking")
        )
        let modelContainer = try ModelContainerFactory.makeContainer(
            inMemory: true
        )
        let context = modelContainer.mainContext
        for summary in [first, second] {
            context.insert(CachedFinancialTransaction(
                summary: summary,
                classification: TransactionClassifier().classify(
                    summary,
                    rules: []
                ),
                requiresNameReview: true
            ))
        }
        context.insert(DurableMerchantRule(
            fingerprint: """
            description:apa treas 310 des misc pay id rsxxxxx00029867 \
            indn botto paul co id xxxxx36151 ppd
            """,
            preferredName: "Treasury Deposit",
            categoryName: "Income",
            forecastTreatment: .income,
            categoryReusable: false,
            ruleSchemaVersion: 2,
            provenance: .user,
            confirmed: true,
            nameConfirmedAt: .now
        ))
        try context.save()
        let coordinator = PlaidTransactionSyncCoordinator(
            client: RecordedPlaidClient(),
            inferenceProvider: RecordedTransactionInferenceProvider(),
            mainContext: context
        )

        coordinator.runLocalMigrationsIfNeeded()

        let rows = try context.fetch(
            FetchDescriptor<CachedFinancialTransaction>()
        )
        let rule = try #require(
            context.fetch(FetchDescriptor<DurableMerchantRule>()).first
        )
        #expect(first.merchantFingerprint == second.merchantFingerprint)
        #expect(rule.ruleSchemaVersion == 4)
        #expect(rule.fingerprint == first.merchantFingerprint)
        #expect(rows.allSatisfy { $0.displayName == "Treasury Deposit" })
        #expect(rows.allSatisfy { !$0.requiresNameReview })
    }

    @Test(.disabled("Replaced by canonical transaction decision coverage"))
    func reviewedPlaidSplitPersistsAndFeedsProjectionLegs() throws {
        let summary = try #require(
            PlaidTransactionDTO(
                id: "split-transaction",
                accountId: "card-1",
                date: "2026-07-24",
                amount: 100,
                name: "BIG STORE",
                merchantName: "Big Store",
                merchantEntityId: "big-store"
            ).financialSummary(canonicalAccountId: "canonical-card")
        )
        let modelContainer = try ModelContainerFactory.makeContainer(inMemory: true)
        let context = modelContainer.mainContext
        context.insert(CachedCategory(
            id: "groceries",
            budgetId: "budget",
            groupId: "living",
            groupName: "Living",
            name: "Groceries"
        ))
        context.insert(CachedCategory(
            id: "household",
            budgetId: "budget",
            groupId: "living",
            groupName: "Living",
            name: "Household"
        ))
        context.insert(CachedFinancialTransaction(
            summary: summary,
            classification: TransactionClassifier().classify(
                summary,
                rules: []
            )
        ))
        try context.save()
        let coordinator = PlaidTransactionSyncCoordinator(
            client: RecordedPlaidClient(),
            inferenceProvider: RecordedTransactionInferenceProvider(),
            mainContext: context
        )
        let splits = [
            SubTransactionSummary(
                id: "split-groceries",
                amount: Money.dollars(-60),
                categoryId: "groceries",
                categoryName: "Groceries",
                payeeName: nil,
                memo: nil,
                deleted: false
            ),
            SubTransactionSummary(
                id: "split-household",
                amount: Money.dollars(-40),
                categoryId: "household",
                categoryName: "Household",
                payeeName: nil,
                memo: nil,
                deleted: false
            )
        ]

        let rejected = coordinator.reviewSplitTransaction(
            id: summary.id,
            displayName: "Big Store",
            subtransactions: Array(splits.prefix(1))
        )
        let saved = coordinator.reviewSplitTransaction(
            id: summary.id,
            displayName: "Big Store",
            subtransactions: splits
        )

        let row = try #require(
            context.fetch(FetchDescriptor<CachedFinancialTransaction>()).first
        )
        let override = try #require(
            context.fetch(FetchDescriptor<DurableTransactionOverride>()).first
        )
        let rule = try #require(
            context.fetch(FetchDescriptor<DurableMerchantRule>()).first
        )
        #expect(!rejected)
        #expect(saved)
        #expect(row.isSplit)
        #expect(row.categoryDisplayName == "Split")
        #expect(row.subtransactions.map(\.amount).sum() == Money.dollars(-100))
        #expect(row.toProjectionSummary()?.subtransactions.count == 2)
        #expect(override.subtransactions.count == 2)
        #expect(!rule.categoryReusable)
        #expect(!row.requiresReview)
    }

    @Test
    func incomingPlaidSplitPersistsIncomeAndReimbursementLegs() throws {
        let summary = try #require(
            PlaidTransactionDTO(
                id: "incoming-split",
                accountId: "checking-1",
                date: "2026-07-24",
                amount: -100,
                name: "DEPOSIT"
            ).financialSummary(
                canonicalAccountId: "canonical-checking"
            )
        )
        let modelContainer = try ModelContainerFactory.makeContainer(
            inMemory: true
        )
        let context = modelContainer.mainContext
        context.insert(CachedFinancialTransaction(
            summary: summary,
            classification: TransactionClassifier().classify(
                summary,
                rules: []
            )
        ))
        try context.save()
        let coordinator = PlaidTransactionSyncCoordinator(
            client: RecordedPlaidClient(),
            inferenceProvider: RecordedTransactionInferenceProvider(),
            mainContext: context
        )
        let invalidExpenseSplit = [
            SubTransactionSummary(
                id: "income",
                amount: Money.dollars(80),
                categoryId: "ynab:expense",
                categoryName: "Eating Out",
                payeeName: nil,
                memo: nil,
                deleted: false
            ),
            SubTransactionSummary(
                id: "reimbursement",
                amount: Money.dollars(20),
                categoryId: nil,
                categoryName: nil,
                forecastTreatment: .reimbursement,
                payeeName: nil,
                memo: nil,
                deleted: false
            )
        ]
        let validSplit = [
            SubTransactionSummary(
                id: "income",
                amount: Money.dollars(80),
                categoryId: nil,
                categoryName: "Income",
                forecastTreatment: .income,
                payeeName: nil,
                memo: nil,
                deleted: false
            ),
            SubTransactionSummary(
                id: "reimbursement",
                amount: Money.dollars(20),
                categoryId: nil,
                categoryName: nil,
                forecastTreatment: .reimbursement,
                payeeName: nil,
                memo: nil,
                deleted: false
            )
        ]

        let rejected = coordinator.reviewSplitTransaction(
            id: summary.id,
            displayName: "Deposit",
            subtransactions: invalidExpenseSplit
        )
        let saved = coordinator.reviewSplitTransaction(
            id: summary.id,
            displayName: "Deposit",
            subtransactions: validSplit
        )

        let row = try #require(
            context.fetch(
                FetchDescriptor<CachedFinancialTransaction>()
            ).first
        )
        let decision = try #require(
            context.fetch(
                FetchDescriptor<DurableCanonicalTransactionDecision>()
            ).first
        )
        #expect(!rejected)
        #expect(saved)
        #expect(!row.requiresReview)
        #expect(row.subtransactions.count == 2)
        #expect(
            row.subtransactions.map(\.forecastTreatment)
                == [.income, .reimbursement]
        )
        #expect(
            decision.subtransactions.map(\.forecastTreatment)
                == [.income, .reimbursement]
        )
        let projection = try #require(row.toProjectionSummary())
        #expect(projection.forecastTreatment == .unknown)
        #expect(
            projection.subtransactions.map(\.forecastTreatment)
                == [.income, .reimbursement]
        )
    }

    @Test func legacySyntheticReimbursementSplitRepairIsTargetedAndIdempotent()
        throws {
        let summary = try #require(
            PlaidTransactionDTO(
                id: "legacy-reimbursement-split",
                accountId: "checking-1",
                date: "2026-07-31",
                amount: -100,
                name: "DEPOSIT"
            ).financialSummary(canonicalAccountId: "canonical-checking")
        )
        let legacyLegs = [
            SubTransactionSummary(
                id: "income",
                amount: Money.dollars(80),
                categoryId: nil,
                categoryName: "Income",
                forecastTreatment: .income,
                payeeName: nil,
                memo: nil,
                deleted: false
            ),
            SubTransactionSummary(
                id: "reimbursement",
                amount: Money.dollars(20),
                categoryId: nil,
                categoryName: "Reimbursement",
                forecastTreatment: .refund,
                payeeName: nil,
                memo: nil,
                deleted: false
            )
        ]
        let legacyData = try JSONEncoder().encode(legacyLegs)
        let container = try ModelContainerFactory.makeContainer(inMemory: true)
        let context = container.mainContext
        let row = CachedFinancialTransaction(
            summary: summary,
            classification: TransactionClassifier().classify(
                summary,
                rules: []
            ),
            subtransactionsData: legacyData
        )
        let decision = DurableCanonicalTransactionDecision(
            transactionExternalId: summary.externalId,
            categoryNameSnapshot: "Split",
            amountSign: 1,
            forecastTreatment: .unknown,
            subtransactionsData: legacyData,
            reviewed: true,
            provenance: .user
        )
        let override = DurableTransactionOverride(
            transactionExternalId: summary.externalId,
            displayName: "Deposit",
            categoryName: "Split",
            forecastTreatment: .unknown,
            subtransactionsData: legacyData,
            provenance: .user
        )
        context.insert(row)
        context.insert(decision)
        context.insert(override)
        try context.save()

        let service = LegacyReimbursementRepairService(context: context)
        let first = try service.repair()
        try context.save()

        #expect(first.cachedTransactions == 1)
        #expect(first.durableDecisions == 1)
        #expect(first.durableOverrides == 1)
        #expect(first.undecodablePayloads == 0)
        #expect(row.subtransactions.map(\.forecastTreatment)
            == [.income, .reimbursement])
        #expect(row.subtransactions[1].categoryName == nil)
        #expect(decision.subtransactions.map(\.forecastTreatment)
            == [.income, .reimbursement])
        #expect(override.subtransactions.map(\.forecastTreatment)
            == [.income, .reimbursement])
        #expect(row.forecastTreatment == .unknown)

        let second = try service.repair()
        #expect(second.repairedRecords == 0)
        #expect(second.undecodablePayloads == 0)
    }

    @Test func legacyWholeReimbursementRepairIncludesExpensesAndPreservesOtherRefunds()
        throws {
        let syntheticSummary = try #require(
            PlaidTransactionDTO(
                id: "legacy-whole-reimbursement",
                accountId: "checking-1",
                date: "2026-07-31",
                amount: -20,
                name: "REIMBURSEMENT"
            ).financialSummary(canonicalAccountId: "canonical-checking")
        )
        let realRefundSummary = try #require(
            PlaidTransactionDTO(
                id: "real-category-refund",
                accountId: "checking-1",
                date: "2026-07-31",
                amount: -15,
                name: "STORE REFUND"
            ).financialSummary(canonicalAccountId: "canonical-checking")
        )
        let expenseSummary = try #require(
            PlaidTransactionDTO(
                id: "legacy-reimbursement-expense",
                accountId: "checking-1",
                date: "2026-07-30",
                amount: 50,
                name: "WORK EXPENSE"
            ).financialSummary(canonicalAccountId: "canonical-checking")
        )
        let container = try ModelContainerFactory.makeContainer(inMemory: true)
        let context = container.mainContext
        let synthetic = CachedFinancialTransaction(
            summary: syntheticSummary,
            classification: TransactionClassification(
                displayName: "Reimbursement",
                categoryName: "Reimbursement",
                treatment: .refund,
                confidence: .high,
                provenance: .user,
                requiresReview: false
            )
        )
        let durableSynthetic = DurableCanonicalTransactionDecision(
            transactionExternalId: syntheticSummary.externalId,
            categoryCanonicalId: LegacyReimbursementRepresentation
                .retiredCanonicalCategoryID,
            categoryNameSnapshot: "Reimbursement - $5K",
            amountSign: 1,
            forecastTreatment: .ordinarySpending,
            reviewed: true,
            provenance: .user
        )
        let realRefund = CachedFinancialTransaction(
            summary: realRefundSummary,
            classification: TransactionClassification(
                displayName: "Store Refund",
                categoryName: "Shopping",
                treatment: .refund,
                confidence: .high,
                provenance: .user,
                requiresReview: false
            )
        )
        realRefund.categoryCanonicalId = "networth:shopping"
        let legacyExpense = CachedFinancialTransaction(
            summary: expenseSummary,
            classification: TransactionClassification(
                displayName: "Work Expense",
                categoryName: nil,
                treatment: .ordinarySpending,
                confidence: .high,
                provenance: .user,
                requiresReview: false
            )
        )
        legacyExpense.nativeCategoryRaw = "other"
        legacyExpense.categoryCanonicalId = LegacyReimbursementRepresentation
            .retiredCanonicalCategoryID
        legacyExpense.categoryName = "Reimbursement - $5K"
        let legacyOverride = DurableTransactionOverride(
            transactionExternalId: "legacy-override",
            displayName: "Expense",
            categoryName: "Reimbursements",
            forecastTreatment: .ordinarySpending,
            provenance: .user
        )
        legacyOverride.categoryRaw = "reimbursements"
        let legacyRule = DurableMerchantRule(
            fingerprint: "legacy-reimbursement-rule",
            preferredName: "Expense",
            categoryName: nil,
            forecastTreatment: .ordinarySpending,
            categoryReusable: true,
            confirmed: true
        )
        legacyRule.categoryRaw = "reimbursements"
        let legacyCategory = DurableCanonicalCategory(
            canonicalId: LegacyReimbursementRepresentation
                .retiredCanonicalCategoryID,
            ynabCategoryId: LegacyReimbursementRepresentation
                .retiredYNABCategoryID,
            name: "Reimbursement - $5K",
            groupName: "Other",
            sourceName: "Reimbursement - $5K",
            sourceGroupName: "Other",
            categoryGroupIdentity: "group:other",
            hidden: false,
            userEdited: true
        )
        context.insert(synthetic)
        context.insert(durableSynthetic)
        context.insert(realRefund)
        context.insert(legacyExpense)
        context.insert(legacyOverride)
        context.insert(legacyRule)
        context.insert(legacyCategory)
        try context.save()

        let result = try LegacyReimbursementRepairService(
            context: context
        ).repair()
        try context.save()

        #expect(result.cachedTransactions == 2)
        #expect(result.durableDecisions == 1)
        #expect(result.durableOverrides == 1)
        #expect(result.merchantRules == 1)
        #expect(result.canonicalCategories == 1)
        #expect(synthetic.forecastTreatment == .reimbursement)
        #expect(synthetic.categoryName == nil)
        #expect(durableSynthetic.forecastTreatment == .reimbursement)
        #expect(durableSynthetic.categoryNameSnapshot == nil)
        #expect(legacyExpense.forecastTreatment == .reimbursement)
        #expect(legacyExpense.nativeCategoryRaw == "other")
        #expect(legacyExpense.categoryCanonicalId == nil)
        #expect(legacyExpense.categoryName == nil)
        #expect(legacyOverride.forecastTreatmentRaw
            == TransactionType.reimbursement.rawValue)
        #expect(legacyOverride.categoryRaw == "other")
        #expect(legacyOverride.categoryName == nil)
        #expect(legacyRule.forecastTreatmentRaw
            == TransactionType.reimbursement.rawValue)
        #expect(legacyRule.categoryRaw == "other")
        #expect(legacyRule.categoryName == nil)
        #expect(!legacyRule.categoryReusable)
        #expect(legacyCategory.hidden)
        #expect(legacyCategory.categoryGroupIdentity == nil)
        #expect(realRefund.forecastTreatment == .refund)
        #expect(realRefund.categoryCanonicalId
            == "networth:shopping")
    }

    @Test func legacyReimbursementRepairPreservesUndecodableSplitData()
        throws {
        let summary = try #require(
            PlaidTransactionDTO(
                id: "undecodable-reimbursement",
                accountId: "checking-1",
                date: "2026-07-31",
                amount: -20,
                name: "DEPOSIT"
            ).financialSummary(canonicalAccountId: "canonical-checking")
        )
        let invalidData = Data("not-json".utf8)
        let container = try ModelContainerFactory.makeContainer(inMemory: true)
        let context = container.mainContext
        let row = CachedFinancialTransaction(
            summary: summary,
            classification: TransactionClassifier().classify(
                summary,
                rules: []
            ),
            subtransactionsData: invalidData
        )
        context.insert(row)
        try context.save()

        let result = try LegacyReimbursementRepairService(
            context: context
        ).repair()

        #expect(result.repairedRecords == 0)
        #expect(result.undecodablePayloads == 1)
        #expect(row.subtransactionsData == invalidData)
        #expect(row.subtransactionsDecodeFailed)
    }

    @Test(.disabled("Replaced by canonical transaction decision coverage"))
    func historicalYNABSplitIsPreservedWithoutBecomingFutureRule() throws {
        let date = try #require(
            Calendar(identifier: .gregorian).date(
                from: DateComponents(year: 2026, month: 7, day: 24)
            )
        )
        let legacyDate = try #require(
            Calendar(identifier: .gregorian).date(
                byAdding: .day,
                value: -2,
                to: date
            )
        )
        let splitLegs = [
            SubTransactionSummary(
                id: "legacy-groceries",
                amount: Money.dollars(-60),
                categoryId: "groceries",
                categoryName: "Groceries",
                payeeName: nil,
                memo: nil,
                deleted: false
            ),
            SubTransactionSummary(
                id: "legacy-household",
                amount: Money.dollars(-40),
                categoryId: "household",
                categoryName: "Household",
                payeeName: nil,
                memo: nil,
                deleted: false
            )
        ]
        let splitData = try JSONEncoder().encode(splitLegs)
        let summary = FinancialTransactionSummary(
            id: "plaid:split-history",
            externalId: "split-history",
            source: .plaid,
            accountId: "canonical-card",
            postedDate: date,
            authorizedDate: nil,
            amount: Money.dollars(-100),
            pending: false,
            pendingTransactionId: nil,
            rawDescription: "BIG STORE",
            originalDescription: "BIG STORE",
            providerMerchantName: "Big Store #123",
            merchantEntityId: "big-store",
            counterpartyName: nil,
            counterpartyType: nil,
            counterpartyEntityId: nil,
            counterpartyConfidence: nil,
            paymentChannel: nil,
            providerCategoryPrimary: "GENERAL_MERCHANDISE",
            providerCategoryDetailed: nil,
            providerCategoryConfidence: "HIGH",
            transactionCode: nil
        )
        let modelContainer = try ModelContainerFactory.makeContainer(inMemory: true)
        let context = modelContainer.mainContext
        context.insert(CachedAccount(
            id: "ynab-card",
            budgetId: "budget",
            name: "Card",
            typeRaw: "creditCard",
            balanceMilliunits: 0,
            clearedMilliunits: 0,
            unclearedMilliunits: 0,
            onBudget: true,
            closed: false,
            deleted: false
        ))
        context.insert(CachedCategory(
            id: "groceries",
            budgetId: "budget",
            groupId: "living",
            groupName: "Living",
            name: "Groceries"
        ))
        context.insert(CachedCategory(
            id: "household",
            budgetId: "budget",
            groupId: "living",
            groupName: "Living",
            name: "Household"
        ))
        context.insert(CachedTransaction(
            id: "ynab-split",
            budgetId: "budget",
            accountId: "ynab-card",
            date: legacyDate,
            amountMilliunits: Money.dollars(-100).milliunits,
            cleared: true,
            approved: true,
            payeeName: "Big Store",
            categoryName: nil,
            memo: nil,
            deleted: false,
            subtransactionsData: splitData
        ))
        context.insert(CachedFinancialTransaction(
            summary: summary,
            classification: TransactionClassifier().classify(
                summary,
                rules: []
            )
        ))
        context.insert(DurableCanonicalAccountBinding(
            canonicalAccountId: "canonical-card",
            plaidAccountId: "card-1",
            ynabAccountId: "ynab-card",
            itemId: "item",
            institutionName: "Bank",
            accountName: "Card",
            accountType: .creditCard,
            reviewed: true
        ))
        try context.save()
        let coordinator = PlaidTransactionSyncCoordinator(
            client: RecordedPlaidClient(),
            inferenceProvider: RecordedTransactionInferenceProvider(),
            mainContext: context
        )

        coordinator.reconcileHistory()

        let row = try #require(
            context.fetch(FetchDescriptor<CachedFinancialTransaction>()).first
        )
        let override = try #require(
            context.fetch(FetchDescriptor<DurableTransactionOverride>()).first
        )
        let rule = try #require(
            context.fetch(FetchDescriptor<DurableMerchantRule>()).first
        )
        #expect(row.subtransactions.count == 2)
        #expect(!row.requiresReview)
        #expect(!row.requiresNameReview)
        #expect(override.subtransactions.count == 2)
        #expect(
            override.provenanceRaw
                == ClassificationProvenance.historicalMatch.rawValue
        )
        #expect(!rule.categoryReusable)
    }

    #if false // Retired provider reference-import coverage retained for history only.
    // MARK: - Retired provider reference import

    @Test func ynabReferenceImportKeepsCategoriesAsEvidenceOnly() async throws {
        func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
            try JSONDecoder().decode(T.self, from: Data(json.utf8))
        }
        let budgets = try decode(
            [YNABBudgetSummary].self,
            #"[{"id":"budget-1","name":"Main","last_modified_on":null,"currency_format":null}]"#
        )
        let payees = try decode(
            YNABPayeesResponse.self,
            #"{"payees":[{"id":"payee-1","name":"Cafe","transfer_account_id":null,"deleted":false}],"server_knowledge":0}"#
        )
        let categories = try decode(
            YNABCategoriesResponse.self,
            #"{"category_groups":[{"id":"grp-food","name":"Food","hidden":false,"deleted":false,"categories":[{"id":"cat-dining","category_group_id":"grp-food","name":"Dining","hidden":false,"deleted":false}]},{"id":"grp-inc","name":"Income","hidden":false,"deleted":false,"categories":[{"id":"cat-pay","category_group_id":"grp-inc","name":"Paycheck","hidden":false,"deleted":false}]}],"server_knowledge":0}"#
        )
        let transactions = try decode(
            YNABTransactionsResponse.self,
            #"{"transactions":[{"id":"y-1","date":"2026-07-24","amount":-42500,"cleared":"cleared","approved":true,"account_id":"ynab-checking","payee_id":"payee-1","payee_name":"Cafe","category_id":"cat-dining","category_name":"Dining","transfer_account_id":null,"transfer_transaction_id":null,"import_id":null,"memo":null,"deleted":false,"subtransactions":[]}],"server_knowledge":0}"#
        )
        let modelContainer = try ModelContainerFactory.makeContainer(inMemory: true)
        let ynabClient = RecordedYNABClient(
            budgets: budgets,
            payees: payees,
            categories: categories,
            transactions: transactions
        )
        let container = AppContainerController(
            secretStore: InMemorySecretStore(seed: [
                .ynabPersonalAccessToken: "token"
            ]),
            biometricGate: ScriptableBiometricGate(isAvailable: false),
            ynabClient: ynabClient,
            plaidClient: RecordedPlaidClient(),
            modelContainer: modelContainer
        )
        await container.bootstrap()
        let ctx = modelContainer.mainContext
        // Seed the reconciled Plaid side after the clean start.
        ctx.insert(CachedFinancialAccount(
            canonicalAccountId: "canonical-checking",
            externalId: "plaid-checking",
            itemId: "bank-item",
            source: .plaid,
            institutionName: "Bank",
            name: "Checking",
            officialName: nil,
            mask: "1234",
            type: .checking,
            subtype: "checking",
            currentBalanceMilliunits: 0,
            availableBalanceMilliunits: nil,
            creditLimitMilliunits: nil,
            isoCurrencyCode: "USD"
        ))
        ctx.insert(DurableCanonicalAccountBinding(
            canonicalAccountId: "canonical-checking",
            plaidAccountId: "plaid-checking",
            ynabAccountId: "ynab-checking",
            itemId: "bank-item",
            institutionName: "Bank",
            accountName: "Checking",
            accountType: .checking,
            reviewed: true
        ))
        let day = try #require(
            YNABTransactionDTO.dateParser.date(from: "2026-07-24")
        )
        ctx.insert(PlaidAccountCoverage(
            plaidAccountId: "plaid-checking",
            itemId: "bank-item",
            earliestImportedDate: day.addingTimeInterval(-86_400 * 30),
            latestImportedDate: day.addingTimeInterval(86_400)
        ))
        let plaidSummary = try #require(
            PlaidTransactionDTO(
                id: "p-1",
                accountId: "plaid-checking",
                date: "2026-07-24",
                amount: 42.50,
                name: "SQ *CAFE",
                merchantName: "Cafe"
            ).financialSummary(canonicalAccountId: "canonical-checking")
        )
        ctx.insert(CachedFinancialTransaction(
            summary: plaidSummary,
            classification: TransactionClassifier().classify(
                plaidSummary, rules: []
            ),
            requiresNameReview: true
        ))
        try ctx.save()

        let succeeded = await container.buildYNABReference()
        #expect(succeeded)

        // Suggestion row carries the matched identities + classification.
        let suggestions = try ctx.fetch(
            FetchDescriptor<YNABReferenceSuggestion>()
        )
        let suggestion = try #require(suggestions.first)
        #expect(suggestions.count == 1)
        #expect(suggestion.ynabTransactionId == "y-1")
        #expect(suggestion.payeeCanonicalId == "ynab:payee-1")
        #expect(suggestion.categoryCanonicalId == nil)
        #expect(suggestion.categoryNameSnapshot == "Dining")
        #expect(suggestion.forecastTreatment == .ordinarySpending)

        // Category names remain evidence only. The import neither calls the
        // categories endpoint nor creates durable categories or groups.
        let categoriesCallCount = await ynabClient.categoriesCallCount
        #expect(categoriesCallCount == 0)
        let groups = try ctx.fetch(FetchDescriptor<DurableCategoryGroup>())
        #expect(!groups.contains { $0.groupIdentity.hasPrefix("ynab:") })
        let canonicalCategories = try ctx.fetch(
            FetchDescriptor<DurableCanonicalCategory>()
        )
        #expect(!canonicalCategories.contains {
            $0.canonicalId.hasPrefix("ynab:") || $0.ynabCategoryId != nil
        })
        #expect(try ctx.fetch(FetchDescriptor<CachedTransaction>()).isEmpty)
        #expect(try ctx.fetch(FetchDescriptor<CachedCategory>()).isEmpty)
        #expect(try ctx.fetch(FetchDescriptor<CachedAccount>()).isEmpty)

        // The Plaid row is prefilled as a suggestion but never auto-approved.
        let row = try #require(
            try ctx.fetch(FetchDescriptor<CachedFinancialTransaction>()).first
        )
        #expect(row.displayName == "Cafe")
        #expect(row.categoryName == "Dining")
        #expect(row.categoryCanonicalId == nil)
        #expect(row.requiresReview == true)
        let userDecisions = try ctx.fetch(
            FetchDescriptor<DurableCanonicalTransactionDecision>()
        ).filter { $0.provenanceRaw == ClassificationProvenance.user.rawValue }
        #expect(userDecisions.isEmpty)
    }

    @Test func legacyYNABSyncCachesCategoriesWithoutMutatingDirectory()
        async throws {
        let budgets = try JSONDecoder().decode(
            [YNABBudgetSummary].self,
            from: Data(
                #"[{"id":"budget-1","name":"Main","last_modified_on":null,"currency_format":null}]"#.utf8
            )
        )
        let categories = try JSONDecoder().decode(
            YNABCategoriesResponse.self,
            from: Data(
                #"{"category_groups":[{"id":"group-1","name":"YNAB Group","hidden":false,"deleted":false,"categories":[{"id":"cat-existing","category_group_id":"group-1","name":"Renamed by YNAB","hidden":false,"deleted":false},{"id":"cat-new","category_group_id":"group-1","name":"New from YNAB","hidden":false,"deleted":false}]}],"server_knowledge":1}"#.utf8
            )
        )
        let modelContainer = try ModelContainerFactory.makeContainer(
            inMemory: true
        )
        let context = modelContainer.mainContext
        let manualCategory = DurableCanonicalCategory(
            canonicalId: "networth:manual",
            ynabCategoryId: "cat-existing",
            name: "My Category",
            groupName: "My Group",
            sourceName: "Old reference name",
            sourceGroupName: "Old reference group",
            userEdited: true
        )
        context.insert(manualCategory)
        try context.save()

        let coordinator = SyncCoordinator(
            client: RecordedYNABClient(
                budgets: budgets,
                categories: categories
            ),
            mainContext: context
        )
        await coordinator.syncAll(budgetId: "budget-1")

        let durableCategories = try context.fetch(
            FetchDescriptor<DurableCanonicalCategory>()
        )
        #expect(durableCategories.count == 1)
        #expect(durableCategories.first?.canonicalId == "networth:manual")
        #expect(durableCategories.first?.name == "My Category")
        #expect(durableCategories.first?.groupName == "My Group")
        #expect(durableCategories.first?.sourceName == "Old reference name")
        #expect(durableCategories.first?.sourceGroupName == "Old reference group")

        let cachedCategories = try context.fetch(
            FetchDescriptor<CachedCategory>()
        )
        #expect(Set(cachedCategories.map(\.id)) == ["cat-existing", "cat-new"])
    }

    #endif

    @Test func approveClusterWritesAuthoritativeDecisionsInOneSave() throws {
        let modelContainer = try ModelContainerFactory.makeContainer(inMemory: true)
        let ctx = modelContainer.mainContext
        ctx.insert(DurableCanonicalPayee(
            canonicalId: "ynab:payee-1", name: "Cafe", sourceName: "Cafe"
        ))
        ctx.insert(DurableCategoryGroup(
            groupIdentity: "ynab:grp-food", name: "Food",
            reportingRole: .spending
        ))
        ctx.insert(DurableCanonicalCategory(
            canonicalId: "ynab:cat-dining",
            name: "Dining",
            groupName: "Food",
            categoryGroupIdentity: "ynab:grp-food"
        ))
        var ids: [String] = []
        for index in 0..<2 {
            let summary = try #require(
                PlaidTransactionDTO(
                    id: "cluster-\(index)",
                    accountId: "card-1",
                    date: "2026-07-2\(index + 1)",
                    amount: 10,
                    name: "SQ *CAFE",
                    merchantName: "Cafe"
                ).financialSummary(canonicalAccountId: "canonical-card")
            )
            ids.append(summary.id)
            ctx.insert(CachedFinancialTransaction(
                summary: summary,
                classification: TransactionClassifier().classify(
                    summary, rules: []
                )
            ))
        }
        try ctx.save()
        let coordinator = PlaidTransactionSyncCoordinator(
            client: RecordedPlaidClient(),
            inferenceProvider: RecordedTransactionInferenceProvider(),
            mainContext: ctx
        )

        let approved = coordinator.approveTransactions(
            ids: ids,
            displayName: "Cafe",
            categoryName: "Dining",
            categoryCanonicalId: "ynab:cat-dining",
            treatment: .ordinarySpending
        )

        #expect(approved == 2)
        let rows = try ctx.fetch(FetchDescriptor<CachedFinancialTransaction>())
        #expect(rows.allSatisfy { !$0.requiresReview })
        let decisions = try ctx.fetch(
            FetchDescriptor<DurableCanonicalTransactionDecision>()
        )
        #expect(decisions.count == 2)
        #expect(decisions.allSatisfy {
            $0.reviewed
                && $0.provenanceRaw == ClassificationProvenance.user.rawValue
        })
    }

    @Test func spendingHistoryUsesOnlyUserGroupsAndMarksYNABAssignmentsUnassigned() async throws {
        let modelContainer = try ModelContainerFactory.makeContainer(
            inMemory: true
        )
        let context = modelContainer.mainContext
        let importedGroup = DurableCategoryGroup(
            groupIdentity: "ynab:living",
            name: "Living",
            reportingRole: .spending
        )
        let userGroup = DurableCategoryGroup(
            groupIdentity: "networth:spending:user:daily",
            name: "Daily Life",
            reportingRole: .spending
        )
        context.insert(importedGroup)
        context.insert(userGroup)
        context.insert(DurableCanonicalCategory(
            canonicalId: "ynab:groceries",
            name: "Groceries",
            groupName: "Living",
            categoryGroupIdentity: importedGroup.groupIdentity
        ))
        context.insert(DurableCanonicalCategory(
            canonicalId: "networth:dining",
            name: "Dining",
            groupName: userGroup.name,
            categoryGroupIdentity: userGroup.groupIdentity
        ))

        let calendar = Calendar.current
        let now = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 5,
            hour: 12
        )))
        func transaction(
            id: String,
            amount: Int64,
            categoryName: String,
            categoryCanonicalId: String
        ) -> CachedFinancialTransaction {
            let summary = FinancialTransactionSummary(
                id: id,
                externalId: id,
                source: .plaid,
                accountId: "checking",
                postedDate: now,
                authorizedDate: nil,
                amount: Money(milliunits: amount),
                pending: false,
                pendingTransactionId: nil,
                rawDescription: categoryName,
                originalDescription: nil,
                providerMerchantName: categoryName,
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
            let row = CachedFinancialTransaction(
                summary: summary,
                classification: TransactionClassification(
                    displayName: categoryName,
                    categoryName: categoryName,
                    treatment: .ordinarySpending,
                    confidence: .high,
                    provenance: .user,
                    requiresReview: false
                ),
                requiresNameReview: false
            )
            row.categoryCanonicalId = categoryCanonicalId
            return row
        }
        context.insert(transaction(
            id: "groceries",
            amount: -100_000,
            categoryName: "Groceries",
            categoryCanonicalId: "ynab:groceries"
        ))
        context.insert(transaction(
            id: "dining",
            amount: -50_000,
            categoryName: "Dining",
            categoryCanonicalId: "networth:dining"
        ))
        try context.save()

        let actor = SpendingHistoryBuildActor(modelContainer: modelContainer)
        let model = try await actor.build(now: now, monthsBack: 1)
        let month = try #require(model.months.first)

        #expect(month.groups.contains {
            $0.id == userGroup.groupIdentity && $0.spentMilliunits == 50_000
        })
        #expect(month.groups.contains {
            $0.id == "networth:spending:unassigned"
                && $0.spentMilliunits == 100_000
        })
        #expect(!month.groups.contains { $0.id == importedGroup.groupIdentity })
    }

    @Test func spendingPlanFollowsDurableGroupOrder() async throws {
        let modelContainer = try ModelContainerFactory.makeContainer(
            inMemory: true
        )
        let context = modelContainer.mainContext
        let fixedID = "networth:spending:user:fixed"
        let necessitiesID = "networth:spending:user:necessities"
        context.insert(DurableCategoryGroup(
            groupIdentity: fixedID,
            name: "Fixed",
            displayOrder: 2
        ))
        context.insert(DurableCategoryGroup(
            groupIdentity: necessitiesID,
            name: "Necessities",
            displayOrder: 0
        ))
        for identity in [fixedID, necessitiesID] {
            context.insert(DurableSpendingGroupBudgetRule(
                groupIdentity: identity,
                effectiveYear: 2026,
                effectiveMonth: 9,
                targetMilliunits: Money.dollars(integer: 1_000).milliunits,
                enabled: true
            ))
        }
        try context.save()

        let now = try #require(Calendar.current.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 4,
            hour: 12
        )))
        let actor = SpendingHistoryBuildActor(modelContainer: modelContainer)
        let model = try await actor.build(now: now, monthsBack: 1)
        let month = try #require(model.months.first)

        #expect(model.budgetSummary(for: month).groups.map(\.groupIdentity) == [
            necessitiesID,
            fixedID
        ])
    }

    @Test func savingsBucketCombinesTransfersChoicesAndPriorMonthAssignment() async throws {
        let modelContainer = try ModelContainerFactory.makeContainer(
            inMemory: true
        )
        let context = modelContainer.mainContext
        let surplusID = "networth:spending:user:surplus"
        let savingsID = "networth:spending:user:savings"
        context.insert(DurableCategoryGroup(
            groupIdentity: surplusID,
            name: "Surplus",
            displayOrder: 0
        ))
        context.insert(DurableCategoryGroup(
            groupIdentity: savingsID,
            name: "Savings",
            displayOrder: 1,
            isSavingsBucket: true
        ))
        context.insert(DurableSpendingGroupBudgetRule(
            groupIdentity: surplusID,
            effectiveYear: 2026,
            effectiveMonth: 8,
            targetMilliunits: Money.dollars(integer: 3_000).milliunits,
            enabled: true
        ))
        context.insert(DurableSpendingGroupBudgetRule(
            groupIdentity: savingsID,
            effectiveYear: 2026,
            effectiveMonth: 8,
            targetMilliunits: Money.dollars(integer: 1_000).milliunits,
            enabled: true
        ))
        context.insert(DurableSavingsBudgetChoice(
            budgetYear: 2026,
            budgetMonth: 8,
            sourceGroupIdentity: surplusID,
            savingsGroupIdentity: savingsID,
            amountMilliunits: Money.dollars(integer: 200).milliunits,
            note: "Skipped takeout"
        ))
        context.insert(CachedFinancialAccount(
            canonicalAccountId: "savings-account",
            externalId: "plaid-savings",
            itemId: "item",
            source: .plaid,
            institutionName: "Bank",
            name: "Savings",
            officialName: nil,
            mask: "1234",
            type: .savings,
            subtype: "savings",
            currentBalanceMilliunits: 450_000,
            availableBalanceMilliunits: 450_000,
            creditLimitMilliunits: nil,
            isoCurrencyCode: "USD"
        ))
        let postedDate = try #require(Calendar.current.date(
            from: DateComponents(year: 2026, month: 9, day: 1, hour: 12)
        ))
        let summary = FinancialTransactionSummary(
            id: "september-transfer",
            externalId: "september-transfer",
            source: .plaid,
            accountId: "savings-account",
            postedDate: postedDate,
            authorizedDate: nil,
            amount: Money.dollars(integer: 450),
            pending: false,
            pendingTransactionId: nil,
            rawDescription: "Transfer",
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
        context.insert(CachedFinancialTransaction(
            summary: summary,
            classification: TransactionClassification(
                displayName: "Transfer to Savings",
                categoryName: nil,
                treatment: .internalTransfer,
                confidence: .high,
                provenance: .user,
                requiresReview: false
            ),
            requiresNameReview: false
        ))
        context.insert(DurableSavingsTransferAssignment(
            transactionId: summary.id,
            savingsGroupIdentity: savingsID,
            assignedYear: 2026,
            assignedMonth: 8
        ))
        try context.save()

        let now = try #require(Calendar.current.date(
            from: DateComponents(year: 2026, month: 9, day: 5, hour: 12)
        ))
        let actor = SpendingHistoryBuildActor(modelContainer: modelContainer)
        let model = try await actor.build(now: now, monthsBack: 2)
        let august = try #require(model.months.first {
            BudgetMonth(containing: $0.month)
                == BudgetMonth(year: 2026, month: 8)
        })
        let september = try #require(model.months.first {
            BudgetMonth(containing: $0.month)
                == BudgetMonth(year: 2026, month: 9)
        })
        let augustBudget = model.budgetSummary(for: august)
        let savings = try #require(augustBudget.groups.first {
            $0.groupIdentity == savingsID
        })
        let surplus = try #require(augustBudget.groups.first {
            $0.groupIdentity == surplusID
        })

        #expect(savings.spent == Money.dollars(integer: 450))
        #expect(savings.baseTarget == Money.dollars(integer: 1_000))
        #expect(savings.additionalTarget == Money.dollars(integer: 200))
        #expect(savings.target == Money.dollars(integer: 1_200))
        #expect(surplus.target == Money.dollars(integer: 2_800))
        #expect(
            model.budgetSummary(for: september).groups.first {
                $0.groupIdentity == savingsID
            }?.spent == .zero
        )
    }

    @Test func confirmRejectsIncompatibleTypeCategoryCombination() throws {
        let modelContainer = try ModelContainerFactory.makeContainer(inMemory: true)
        let ctx = modelContainer.mainContext
        ctx.insert(DurableCategoryGroup(
            groupIdentity: "ynab:grp-inc", name: "Income",
            reportingRole: .income
        ))
        ctx.insert(DurableCanonicalCategory(
            canonicalId: "ynab:cat-pay",
            name: "Paycheck",
            groupName: "Income",
            categoryGroupIdentity: "ynab:grp-inc"
        ))
        let summary = try #require(
            PlaidTransactionDTO(
                id: "deposit-1",
                accountId: "checking-1",
                date: "2026-07-24",
                amount: -2_000,
                name: "EMPLOYER PAYROLL"
            ).financialSummary(canonicalAccountId: "canonical-checking")
        )
        ctx.insert(CachedFinancialTransaction(
            summary: summary,
            classification: TransactionClassifier().classify(
                summary, rules: []
            )
        ))
        try ctx.save()
        let coordinator = PlaidTransactionSyncCoordinator(
            client: RecordedPlaidClient(),
            inferenceProvider: RecordedTransactionInferenceProvider(),
            mainContext: ctx
        )

        // An income-group category on an expense must not save; the same
        // category with the income type must.
        #expect(!coordinator.confirmTransaction(
            id: summary.id,
            displayName: "Employer",
            categoryName: "Paycheck",
            treatment: .ordinarySpending,
            categoryCanonicalId: "ynab:cat-pay"
        ))
        #expect(coordinator.confirmTransaction(
            id: summary.id,
            displayName: "Employer",
            categoryName: "Paycheck",
            treatment: .income,
            categoryCanonicalId: "ynab:cat-pay"
        ))
    }

    @Test func expenseFundingChoiceUsesExistingGoalAndReserveRecords() throws {
        let modelContainer = try ModelContainerFactory.makeContainer(
            inMemory: true
        )
        let context = modelContainer.mainContext
        let group = DurableCategoryGroup(
            groupIdentity: "group:necessities",
            name: "Necessities",
            reportingRole: .spending
        )
        let category = DurableCanonicalCategory(
            canonicalId: "category:insurance",
            name: "Insurance",
            groupName: group.name,
            categoryGroupIdentity: group.groupIdentity
        )
        let payee = DurableCanonicalPayee(
            canonicalId: "payee:insurer",
            name: "Insurer",
            sourceName: "Insurer"
        )
        let goal = DurableGoal(name: "House")
        let month = BudgetMonth(containing: .now)
        let reserve = DurableSpendingSinkingFund(
            name: "Annual insurance",
            startYear: month.year,
            startMonth: month.month
        )
        let summary = try #require(
            PlaidTransactionDTO(
                id: "funded-expense",
                accountId: "checking-1",
                date: "2026-08-24",
                amount: 80,
                name: "INSURER",
                merchantName: "Insurer"
            ).financialSummary(canonicalAccountId: "canonical-checking")
        )
        let transaction = CachedFinancialTransaction(
            summary: summary,
            classification: TransactionClassifier().classify(
                summary, rules: []
            )
        )
        context.insert(group)
        context.insert(category)
        context.insert(payee)
        context.insert(goal)
        context.insert(reserve)
        context.insert(transaction)
        try context.save()
        let coordinator = PlaidTransactionSyncCoordinator(
            client: RecordedPlaidClient(),
            inferenceProvider: RecordedTransactionInferenceProvider(),
            mainContext: context
        )

        #expect(coordinator.confirmTransaction(
            id: transaction.id,
            displayName: payee.name,
            categoryName: category.name,
            treatment: .goalSpend,
            categoryCanonicalId: category.canonicalId,
            goalId: goal.id
        ))
        #expect(transaction.forecastTreatment == .goalSpend)
        #expect(transaction.categoryCanonicalId == category.canonicalId)
        #expect(transaction.goalId == goal.id)
        let goalRequest = try #require(context.fetch(
            FetchDescriptor<DurableGoalTransferRequest>()
        ).first)
        #expect(goalRequest.active)
        #expect(goalRequest.goalId == goal.id)

        #expect(coordinator.confirmTransaction(
            id: transaction.id,
            displayName: payee.name,
            categoryName: category.name,
            treatment: .ordinarySpending,
            categoryCanonicalId: category.canonicalId,
            reserveFundId: reserve.id
        ))
        #expect(transaction.forecastTreatment == .ordinarySpending)
        #expect(transaction.goalId == nil)
        #expect(!goalRequest.active)
        let reserveExpense = try #require(context.fetch(
            FetchDescriptor<DurableSpendingSinkingFundExpense>()
        ).first)
        #expect(reserveExpense.active)
        #expect(reserveExpense.fundId == reserve.id)
        #expect(
            reserveExpense.amountMilliunits
                == Money.dollars(integer: 80).milliunits
        )

        #expect(coordinator.confirmTransaction(
            id: transaction.id,
            displayName: payee.name,
            categoryName: category.name,
            treatment: .ordinarySpending,
            categoryCanonicalId: category.canonicalId
        ))
        #expect(!reserveExpense.active)
    }

    @Test func splitExpenseFundingTracksEachPartIndependently() throws {
        let modelContainer = try ModelContainerFactory.makeContainer(
            inMemory: true
        )
        let context = modelContainer.mainContext
        let group = DurableCategoryGroup(
            groupIdentity: "group:necessities",
            name: "Necessities",
            reportingRole: .spending
        )
        let category = DurableCanonicalCategory(
            canonicalId: "category:household",
            name: "Household",
            groupName: group.name,
            categoryGroupIdentity: group.groupIdentity
        )
        let goal = DurableGoal(name: "House")
        let month = BudgetMonth(containing: .now)
        let reserve = DurableSpendingSinkingFund(
            name: "Home repair",
            startYear: month.year,
            startMonth: month.month
        )
        let summary = try #require(
            PlaidTransactionDTO(
                id: "split-funded-expense",
                accountId: "checking-1",
                date: "2026-09-02",
                amount: 100,
                name: "HOME STORE"
            ).financialSummary(canonicalAccountId: "canonical-checking")
        )
        let transaction = CachedFinancialTransaction(
            summary: summary,
            classification: TransactionClassifier().classify(
                summary, rules: []
            )
        )
        context.insert(group)
        context.insert(category)
        context.insert(goal)
        context.insert(reserve)
        context.insert(transaction)
        try context.save()
        let coordinator = PlaidTransactionSyncCoordinator(
            client: RecordedPlaidClient(),
            inferenceProvider: RecordedTransactionInferenceProvider(),
            mainContext: context
        )
        let fundedSplits = [
            SubTransactionSummary(
                id: "reserve-part",
                amount: Money.dollars(-60),
                categoryId: category.canonicalId,
                categoryName: category.name,
                categoryCanonicalId: category.canonicalId,
                forecastTreatment: .ordinarySpending,
                payeeName: nil,
                memo: nil,
                deleted: false
            ),
            SubTransactionSummary(
                id: "goal-part",
                amount: Money.dollars(-40),
                categoryId: category.canonicalId,
                categoryName: category.name,
                categoryCanonicalId: category.canonicalId,
                goalId: goal.id,
                forecastTreatment: .goalSpend,
                payeeName: nil,
                memo: nil,
                deleted: false
            ),
        ]

        #expect(coordinator.reviewSplitTransaction(
            id: transaction.id,
            displayName: "Home Store",
            subtransactions: fundedSplits,
            reserveFundIdBySubtransactionId: [
                "reserve-part": reserve.id
            ]
        ))
        #expect(transaction.subtransactions.map(\.forecastTreatment)
            == [.ordinarySpending, .goalSpend])
        #expect(transaction.subtransactions.allSatisfy {
            $0.categoryCanonicalId == category.canonicalId
        })
        let reserveExpense = try #require(context.fetch(
            FetchDescriptor<DurableSpendingSinkingFundExpense>()
        ).first)
        #expect(reserveExpense.active)
        #expect(reserveExpense.fundId == reserve.id)
        #expect(reserveExpense.subtransactionId == "reserve-part")
        #expect(
            reserveExpense.amountMilliunits
                == Money.dollars(integer: 60).milliunits
        )

        let monthlySplits = fundedSplits.map {
            SubTransactionSummary(
                id: $0.id,
                amount: $0.amount,
                categoryId: category.canonicalId,
                categoryName: category.name,
                categoryCanonicalId: category.canonicalId,
                forecastTreatment: .ordinarySpending,
                payeeName: nil,
                memo: nil,
                deleted: false
            )
        }
        #expect(coordinator.reviewSplitTransaction(
            id: transaction.id,
            displayName: "Home Store",
            subtransactions: monthlySplits
        ))
        #expect(!reserveExpense.active)
        #expect(transaction.subtransactions.allSatisfy {
            $0.forecastTreatment == .ordinarySpending
        })
    }

    @Test func savingsReviewPersistsAndReleasesWholeAndSplitMonths() throws {
        let modelContainer = try ModelContainerFactory.makeContainer(
            inMemory: true
        )
        let context = modelContainer.mainContext
        let savingsGroup = DurableCategoryGroup(
            groupIdentity: "group:savings",
            name: "Savings",
            isSavingsBucket: true
        )
        let summary = try #require(
            PlaidTransactionDTO(
                id: "savings-outflow",
                accountId: "checking-1",
                date: "2026-09-02",
                amount: 100,
                name: "TRANSFER TO SAVINGS"
            ).financialSummary(canonicalAccountId: "canonical-checking")
        )
        let transaction = CachedFinancialTransaction(
            summary: summary,
            classification: TransactionClassifier().classify(
                summary, rules: []
            )
        )
        context.insert(savingsGroup)
        context.insert(transaction)
        try context.save()
        let coordinator = PlaidTransactionSyncCoordinator(
            client: RecordedPlaidClient(),
            inferenceProvider: RecordedTransactionInferenceProvider(),
            mainContext: context
        )
        let august = BudgetMonth(year: 2026, month: 8)
        let september = august.next

        #expect(coordinator.confirmTransaction(
            id: transaction.id,
            displayName: "Savings Transfer",
            categoryName: nil,
            treatment: .savings,
            savingsMonth: august
        ))
        var assignments = try context.fetch(
            FetchDescriptor<DurableSavingsTransferAssignment>()
        )
        let whole = try #require(assignments.first)
        #expect(whole.active)
        #expect(whole.subtransactionId.isEmpty)
        #expect(whole.assignedBudgetMonth == august)

        let splits = [
            SubTransactionSummary(
                id: "august",
                amount: Money.dollars(-60),
                categoryId: nil,
                categoryName: nil,
                forecastTreatment: .savings,
                payeeName: nil,
                memo: nil,
                deleted: false
            ),
            SubTransactionSummary(
                id: "september",
                amount: Money.dollars(-40),
                categoryId: nil,
                categoryName: nil,
                forecastTreatment: .savings,
                payeeName: nil,
                memo: nil,
                deleted: false
            ),
        ]
        #expect(coordinator.reviewSplitTransaction(
            id: transaction.id,
            displayName: "Savings Transfer",
            subtransactions: splits,
            savingsMonthBySubtransactionId: [
                "august": august,
                "september": september,
            ]
        ))
        assignments = try context.fetch(
            FetchDescriptor<DurableSavingsTransferAssignment>()
        )
        #expect(!whole.active)
        #expect(assignments.filter { $0.active }.count == 2)
        #expect(Set(assignments.filter { $0.active }.map {
            $0.assignedBudgetMonth
        }) == [august, september])

        #expect(coordinator.confirmTransaction(
            id: transaction.id,
            displayName: "Savings Transfer",
            categoryName: nil,
            treatment: .internalTransfer
        ))
        #expect(assignments.allSatisfy { !$0.active })
    }

    @Test func legacySavingsMigrationRequeuesOnlyTheOutgoingMatch() throws {
        let modelContainer = try ModelContainerFactory.makeContainer(
            inMemory: true
        )
        let context = modelContainer.mainContext
        context.insert(CachedFinancialAccount(
            canonicalAccountId: "checking",
            externalId: "checking",
            itemId: "item",
            source: .plaid,
            institutionName: "Bank",
            name: "Checking",
            officialName: nil,
            mask: nil,
            type: .checking,
            subtype: "checking",
            currentBalanceMilliunits: 0,
            availableBalanceMilliunits: 0,
            creditLimitMilliunits: nil,
            isoCurrencyCode: "USD"
        ))
        context.insert(CachedFinancialAccount(
            canonicalAccountId: "savings",
            externalId: "savings",
            itemId: "item",
            source: .plaid,
            institutionName: "Bank",
            name: "Savings",
            officialName: nil,
            mask: nil,
            type: .savings,
            subtype: "savings",
            currentBalanceMilliunits: 0,
            availableBalanceMilliunits: 0,
            creditLimitMilliunits: nil,
            isoCurrencyCode: "USD"
        ))
        let outgoingSummary = try #require(PlaidTransactionDTO(
            id: "outgoing",
            accountId: "checking",
            date: "2026-09-01",
            amount: 1_000,
            name: "TRANSFER TO SAVINGS"
        ).financialSummary(canonicalAccountId: "checking"))
        let depositSummary = try #require(PlaidTransactionDTO(
            id: "deposit",
            accountId: "savings",
            date: "2026-09-02",
            amount: -1_000,
            name: "TRANSFER FROM CHECKING"
        ).financialSummary(canonicalAccountId: "savings"))
        let classification = TransactionClassification(
            displayName: "Savings Transfer",
            categoryName: nil,
            treatment: .internalTransfer,
            confidence: .high,
            provenance: .user,
            requiresReview: false
        )
        let outgoing = CachedFinancialTransaction(
            summary: outgoingSummary,
            classification: classification
        )
        let deposit = CachedFinancialTransaction(
            summary: depositSummary,
            classification: classification
        )
        context.insert(outgoing)
        context.insert(deposit)
        try context.save()
        let coordinator = PlaidTransactionSyncCoordinator(
            client: RecordedPlaidClient(),
            inferenceProvider: RecordedTransactionInferenceProvider(),
            mainContext: context
        )

        #expect(coordinator.stageLegacySavingsCandidatesForReview() == 1)
        #expect(outgoing.requiresReview)
        #expect(!deposit.requiresReview)
    }

    @Test func reserveLedgerAssignmentsAreExplicitAndPurchasesAreReversible() throws {
        let modelContainer = try ModelContainerFactory.makeContainer(
            inMemory: true
        )
        let context = modelContainer.mainContext
        let month = BudgetMonth(containing: .now)
        let fund = DurableSpendingSinkingFund(
            name: "Home repair",
            mode: .ongoingReserve,
            plannedMonthlyMilliunits: Money.dollars(integer: 150).milliunits,
            openingBalanceMilliunits: Money.dollars(integer: 300).milliunits,
            startYear: month.year,
            startMonth: month.month
        )
        context.insert(fund)
        let legacyAutomatic = DurableSpendingSinkingFundContribution(
            fundId: fund.id,
            budgetYear: month.year,
            budgetMonth: month.month,
            amountMilliunits: Money.dollars(integer: 150).milliunits,
            origin: .legacyAutomatic
        )
        context.insert(legacyAutomatic)
        try context.save()
        let service = SpendingSinkingFundLedgerService(context: context)

        #expect(!legacyAutomatic.coreContribution.active)

        #expect(service.saveAssignment(
            fundID: fund.id,
            month: month,
            sourceGroupIdentity: "necessities",
            amount: Money.dollars(integer: 125),
            maximum: Money.dollars(integer: 500)
        ))
        var contributions = try context.fetch(
            FetchDescriptor<DurableSpendingSinkingFundContribution>()
        )
        let first = try #require(contributions.first {
            $0.origin == .explicit
        })
        #expect(service.saveAssignment(
            id: first.id,
            fundID: fund.id,
            month: month,
            sourceGroupIdentity: "necessities",
            amount: Money.dollars(integer: 150),
            maximum: Money.dollars(integer: 500)
        ))
        #expect(service.saveAssignment(
            fundID: fund.id,
            month: month,
            sourceGroupIdentity: "surplus",
            amount: Money.dollars(integer: 25),
            maximum: Money.dollars(integer: 300)
        ))
        contributions = try context.fetch(
            FetchDescriptor<DurableSpendingSinkingFundContribution>()
        )
        #expect(contributions.count == 3)
        #expect(
            contributions.filter { $0.coreContribution.active }
                .map { Money(milliunits: $0.amountMilliunits) }.sum()
                == Money.dollars(integer: 175)
        )
        #expect(first.amountMilliunits == Money.dollars(integer: 150).milliunits)
        #expect(first.sourceGroupIdentity == "necessities")
        let second = try #require(contributions.first {
            $0.coreContribution.active && $0.id != first.id
        })
        #expect(second.sourceGroupIdentity == "surplus")
        #expect(service.removeAssignment(second))
        #expect(!second.active)
        #expect(!service.saveAssignment(
            fundID: fund.id,
            month: month,
            sourceGroupIdentity: "necessities",
            amount: Money.dollars(integer: 501),
            maximum: Money.dollars(integer: 500)
        ))

        #expect(service.assign(
            fundID: fund.id,
            transactionID: "repair",
            subtransactionID: nil,
            date: .now,
            amount: Money.dollars(integer: 80)
        ))
        let assigned = try #require(context.fetch(
            FetchDescriptor<DurableSpendingSinkingFundExpense>()
        ).first)
        #expect(assigned.active)
        #expect(service.release(assigned))
        #expect(!assigned.active)
    }

    @Test func reserveLedgerCanAddAndEditAPriorMonthAssignment() throws {
        let modelContainer = try ModelContainerFactory.makeContainer(
            inMemory: true
        )
        let context = modelContainer.mainContext
        let currentMonth = BudgetMonth(containing: .now)
        let priorMonth = currentMonth.previous
        let fund = DurableSpendingSinkingFund(
            name: "Car repair",
            mode: .ongoingReserve,
            startYear: currentMonth.year,
            startMonth: currentMonth.month
        )
        context.insert(fund)
        try context.save()
        let service = SpendingSinkingFundLedgerService(context: context)

        #expect(service.saveAssignment(
            fundID: fund.id,
            month: priorMonth,
            sourceGroupIdentity: "flexible",
            amount: Money.dollars(integer: 80),
            maximum: Money.dollars(integer: 200)
        ))
        let assignment = try #require(context.fetch(
            FetchDescriptor<DurableSpendingSinkingFundContribution>()
        ).first)
        #expect(assignment.budgetYear == priorMonth.year)
        #expect(assignment.budgetMonth == priorMonth.month)

        #expect(service.saveAssignment(
            id: assignment.id,
            fundID: fund.id,
            month: priorMonth,
            sourceGroupIdentity: "flexible",
            amount: Money.dollars(integer: 95),
            maximum: Money.dollars(integer: 200)
        ))
        #expect(assignment.budgetYear == priorMonth.year)
        #expect(assignment.budgetMonth == priorMonth.month)
        #expect(
            assignment.amountMilliunits
                == Money.dollars(integer: 95).milliunits
        )
    }

    @Test func reserveLifecyclePreservesArchiveAndDeletesOnlyPlanningRecords()
        throws {
        let modelContainer = try ModelContainerFactory.makeContainer(
            inMemory: true
        )
        let context = modelContainer.mainContext
        let month = BudgetMonth(containing: .now)
        let fund = DurableSpendingSinkingFund(
            name: "Test reserve",
            startYear: month.year,
            startMonth: month.month
        )
        let otherFund = DurableSpendingSinkingFund(
            name: "Keep reserve",
            startYear: month.year,
            startMonth: month.month
        )
        context.insert(fund)
        context.insert(otherFund)
        context.insert(DurableSpendingSinkingFundContribution(
            fundId: fund.id,
            budgetYear: month.year,
            budgetMonth: month.month,
            sourceGroupIdentity: "flexible",
            amountMilliunits: Money.dollars(integer: 40).milliunits
        ))
        context.insert(DurableSpendingSinkingFundContribution(
            fundId: fund.id,
            budgetYear: month.year,
            budgetMonth: month.month,
            sourceGroupIdentity: "flexible",
            amountMilliunits: Money.dollars(integer: 10).milliunits,
            active: false
        ))
        context.insert(DurableSpendingSinkingFundContribution(
            fundId: otherFund.id,
            budgetYear: month.year,
            budgetMonth: month.month,
            sourceGroupIdentity: "flexible",
            amountMilliunits: Money.dollars(integer: 25).milliunits
        ))
        context.insert(DurableSpendingSinkingFundExpense(
            fundId: fund.id,
            transactionId: "test-purchase",
            amountMilliunits: Money.dollars(integer: 15).milliunits
        ))
        context.insert(DurableSpendingSinkingFundExpense(
            fundId: fund.id,
            transactionId: "old-test-purchase",
            amountMilliunits: Money.dollars(integer: 5).milliunits,
            active: false
        ))
        context.insert(DurableSpendingSinkingFundExpense(
            fundId: otherFund.id,
            transactionId: "keep-purchase",
            amountMilliunits: Money.dollars(integer: 20).milliunits
        ))
        let transactionSummary = try #require(PlaidTransactionDTO(
            id: "test-purchase",
            accountId: "checking",
            date: "2026-09-04",
            amount: 15,
            name: "TEST PURCHASE"
        ).financialSummary(canonicalAccountId: "checking"))
        context.insert(CachedFinancialTransaction(
            summary: transactionSummary,
            classification: TransactionClassification(
                displayName: "Test Purchase",
                categoryName: "Shopping",
                treatment: .ordinarySpending,
                confidence: .high,
                provenance: .user,
                requiresReview: false
            )
        ))
        try context.save()
        let service = SpendingSinkingFundLedgerService(context: context)

        #expect(service.setArchived(true, fundID: fund.id))
        #expect(fund.archived)
        #expect(try context.fetch(
            FetchDescriptor<DurableSpendingSinkingFundContribution>()
        ).filter { $0.fundId == fund.id }.count == 2)
        #expect(try context.fetch(
            FetchDescriptor<DurableSpendingSinkingFundExpense>()
        ).filter { $0.fundId == fund.id }.count == 2)

        #expect(service.setArchived(false, fundID: fund.id))
        #expect(!fund.archived)
        #expect(service.deleteFund(fundID: fund.id))

        #expect(try context.fetch(
            FetchDescriptor<DurableSpendingSinkingFund>()
        ).map(\.id) == [otherFund.id])
        #expect(try context.fetch(
            FetchDescriptor<DurableSpendingSinkingFundContribution>()
        ).allSatisfy { $0.fundId == otherFund.id })
        #expect(try context.fetch(
            FetchDescriptor<DurableSpendingSinkingFundExpense>()
        ).allSatisfy { $0.fundId == otherFund.id })
        #expect(try context.fetch(
            FetchDescriptor<CachedFinancialTransaction>()
        ).contains { $0.id == "test-purchase" })
    }

    // MARK: - Helpers

    private func linkedLoanSnapshot(
        asOf: Date,
        principal: Int,
        accruedInterest: Int,
        weightedInterestRatePercent: Decimal? = nil
    ) -> SharedIBRLoanSnapshot {
        SharedIBRLoanSnapshot(
            asOf: asOf,
            principalMilliunits: Money.dollars(integer: principal).milliunits,
            accruedInterestMilliunits: Money.dollars(integer: accruedInterest).milliunits,
            weightedInterestRatePercent: weightedInterestRatePercent,
            actualMonthlyPaymentMilliunits: Money.dollars(500).milliunits,
            servicerName: "Example Servicer",
            forgivenessDate: Date(timeIntervalSince1970: 3_000_000),
            qualifyingPayments: 120,
            forgivenessThreshold: 300
        )
    }

    private func seedAccountWithRecentTransactions(into ctx: ModelContext, budgetId: String) {
        let account = CachedAccount(
            id: "a1",
            budgetId: budgetId,
            name: "Checking",
            typeRaw: "checking",
            balanceMilliunits: Money.dollars(5_000).milliunits,
            clearedMilliunits: Money.dollars(5_000).milliunits,
            unclearedMilliunits: 0,
            onBudget: true,
            closed: false,
            deleted: false
        )
        ctx.insert(account)

        let cal = Calendar(identifier: .gregorian)
        for offset in [3, 30, 180] {
            let date = cal.date(byAdding: .day, value: -offset, to: .now)!
            ctx.insert(CachedTransaction(
                id: "t\(offset)",
                budgetId: budgetId,
                accountId: "a1",
                date: date,
                amountMilliunits: Money.dollars(-50).milliunits,
                cleared: true,
                approved: true,
                payeeName: "Coffee",
                categoryName: nil,
                memo: nil,
                deleted: false
            ))
        }
    }
}

@Suite("Dashboard presentation")
struct DashboardPresentationTests {
    @Test func projectionHeroUsesTheMostActionableMetric() {
        let available = Money.dollars(6_823)
        let gap = Money.dollars(700)

        #expect(
            ProjectionHeroMetric.resolve(
                setupIncomplete: true,
                canLeadWithSpendingRoom: true,
                availableAmount: available,
                showsPaymentFundingHeadline: false,
                status: .covered,
                headlineAmount: available
            ) == ProjectionHeroMetric(
                kind: .setup,
                label: "Setup needed",
                amount: nil
            )
        )
        #expect(
            ProjectionHeroMetric.resolve(
                setupIncomplete: false,
                canLeadWithSpendingRoom: true,
                availableAmount: available,
                showsPaymentFundingHeadline: false,
                status: .covered,
                headlineAmount: gap
            ).kind == .available
        )
        #expect(
            ProjectionHeroMetric.resolve(
                setupIncomplete: false,
                canLeadWithSpendingRoom: false,
                availableAmount: nil,
                showsPaymentFundingHeadline: true,
                status: .covered,
                headlineAmount: gap
            ).kind == .transferNeeded
        )
        #expect(
            ProjectionHeroMetric.resolve(
                setupIncomplete: false,
                canLeadWithSpendingRoom: false,
                availableAmount: nil,
                showsPaymentFundingHeadline: false,
                status: .tight,
                headlineAmount: gap
            ).kind == .bufferGap
        )
        #expect(
            ProjectionHeroMetric.resolve(
                setupIncomplete: false,
                canLeadWithSpendingRoom: false,
                availableAmount: nil,
                showsPaymentFundingHeadline: false,
                status: .shortfall,
                headlineAmount: -gap
            ).kind == .projectedBalance
        )
    }
}
