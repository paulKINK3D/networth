import Foundation
import Testing
import SwiftData
@testable import Networth
import NetworthCore

@MainActor
@Suite("AppContainer wiring")
struct AppContainerTests {

    @Test func bootstrapWithBiometricAvailableLocksUntilUnlock() async {
        // With biometrics available (the ScriptableBiometricGate default) and
        // the shipped Face-ID-on-by-default behavior, bootstrap should leave
        // the app locked behind the biometric prompt regardless of token state.
        let container = AppContainerController.makePreview()
        await container.bootstrap()
        #expect(container.unlocked == false)
        #expect(container.hasYNABToken == false)
    }

    @Test func bootstrapWithBiometricUnavailableLeavesUnlocked() async {
        // When the device cannot use biometrics, the Face ID gate cannot
        // engage and the app must boot straight into the tabs.
        let container = AppContainerController(
            secretStore: InMemorySecretStore(),
            biometricGate: ScriptableBiometricGate(isAvailable: false),
            ynabClient: RecordedYNABClient(),
            modelContainer: try! ModelContainerFactory.makeContainer(inMemory: true)
        )
        await container.bootstrap()
        #expect(container.unlocked == true)
        #expect(container.hasYNABToken == false)
    }

    @Test func saveAndClearYNABTokenUpdatesFlag() async throws {
        let container = AppContainerController.makePreview()
        await container.bootstrap()
        try await container.saveYNABToken("test-token")
        #expect(container.hasYNABToken == true)
        try await container.clearYNABToken()
        #expect(container.hasYNABToken == false)
    }

    @Test func bootstrapConfiguresPlaidBackendTokenWithoutExposingPlaidSecrets() async {
        let plaidClient = RecordedPlaidClient()
        let container = AppContainerController(
            secretStore: InMemorySecretStore(seed: [.plaidBackendBearerToken: "backend-token"]),
            biometricGate: ScriptableBiometricGate(isAvailable: false),
            ynabClient: RecordedYNABClient(),
            plaidClient: plaidClient,
            modelContainer: try! ModelContainerFactory.makeContainer(inMemory: true)
        )

        await container.bootstrap()

        let configuredToken = await plaidClient.configuredBearerToken
        #expect(container.hasPlaidBackendToken)
        #expect(configuredToken == "backend-token")
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
            ynabClient: RecordedYNABClient(),
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

        treatment.treatment = .duplicateYNAB
        try context.save()
        #expect(scheduler.computeBreakdown().investments == .zero)

        treatment.treatment = .included
        try context.save()
        #expect(scheduler.computeBreakdown().investments == Money.dollars(25_000))
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

    @Test func bootstrapMigratesProjectionLookback() async throws {
        let modelContainer = try ModelContainerFactory.makeContainer(inMemory: true)
        let settings = DurableUserSettings()
        settings.settingsSchemaVersion = 2
        settings.spendingLookbackDays = 60
        modelContainer.mainContext.insert(settings)
        try modelContainer.mainContext.save()
        let container = AppContainerController(
            secretStore: InMemorySecretStore(),
            biometricGate: ScriptableBiometricGate(isAvailable: false),
            ynabClient: RecordedYNABClient(),
            modelContainer: modelContainer
        )

        await container.bootstrap()

        #expect(settings.settingsSchemaVersion == 3)
        #expect(settings.spendingLookbackDays == 365)
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

    @Test func refreshIfStaleUsesFifteenMinuteWindow() async throws {
        let client = RecordedYNABClient()
        let container = AppContainerController(
            secretStore: InMemorySecretStore(seed: [.ynabPersonalAccessToken: "token"]),
            biometricGate: ScriptableBiometricGate(isAvailable: false),
            ynabClient: client,
            modelContainer: try ModelContainerFactory.makeContainer(inMemory: true)
        )
        await container.bootstrap()
        let settings = try #require(try container.modelContainer.mainContext
            .fetch(FetchDescriptor<DurableUserSettings>()).first)
        let syncedAt = Date.now
        settings.lastSyncedAt = syncedAt
        try container.modelContainer.mainContext.save()

        await container.refreshIfStale(now: syncedAt.addingTimeInterval(14 * 60))
        let recentCallCount = await client.budgetsCallCount
        #expect(recentCallCount == 0)

        await container.refreshIfStale(now: syncedAt.addingTimeInterval(16 * 60))
        let staleCallCount = await client.budgetsCallCount
        #expect(staleCallCount == 1)
    }

    @Test func snapshotIsIdempotentForSameDay() async {
        let container = AppContainerController.makePreview()
        await container.bootstrap()
        let first = container.snapshotScheduler.recordIfNeeded()
        let second = container.snapshotScheduler.recordIfNeeded()
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
            ynabClient: RecordedYNABClient(),
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
            ynabClient: RecordedYNABClient(),
            modelContainer: try ModelContainerFactory.makeContainer(inMemory: true),
            ibrLoanStore: InMemoryIBRLoanStore(
                document: SharedIBRLoanDocument(current: snapshot, history: [snapshot])
            ),
            ibrLoanHistorySettingsStore: historySettings
        )

        await container.bootstrap()
        container.setLinkedIBRLoanHistoryStartDate(overrideDate)

        #expect(historySettings.startDate == overrideDate)
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

    @Test func linkedIBRLoanDefaultsToEarliestYNABTransaction() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let ynabStart = calendar.date(
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
        modelContainer.mainContext.insert(CachedTransaction(
            id: "starting-balance",
            budgetId: "budget",
            accountId: "checking",
            date: ynabStart,
            amountMilliunits: Money.dollars(1_000).milliunits,
            cleared: true,
            approved: true,
            payeeName: "Starting Balance",
            categoryName: nil,
            memo: nil,
            deleted: false
        ))
        try modelContainer.mainContext.save()
        let container = AppContainerController(
            secretStore: InMemorySecretStore(),
            biometricGate: ScriptableBiometricGate(isAvailable: false),
            ynabClient: RecordedYNABClient(),
            modelContainer: modelContainer,
            ibrLoanStore: InMemoryIBRLoanStore(
                document: SharedIBRLoanDocument(current: snapshot, history: [snapshot])
            ),
            ibrLoanHistorySettingsStore: InMemoryIBRLoanHistorySettingsStore()
        )
        await container.bootstrap()
        container.selectedBudgetId = "budget"

        #expect(
            container.defaultLinkedIBRLoanHistoryStartDate(calendar: calendar) == ynabStart
        )
        #expect(
            container.linkedIBRLoanBalance(on: ynabStart, calendar: calendar)
                == Money.dollars(90_000)
        )
    }

    // MARK: - Historical backfill

    @Test func backfillWritesReconstructedSnapshots() async throws {
        let container = AppContainerController.makePreview()
        await container.bootstrap()
        let ctx = container.modelContainer.mainContext

        seedAccountWithRecentTransactions(into: ctx, budgetId: "b1")
        try ctx.save()

        container.syncCoordinator.runHistoryBackfillIfNeeded(budgetId: "b1")

        let snaps = try ctx.fetch(FetchDescriptor<DurableNetWorthSnapshot>())
        #expect(snaps.count > 1)
        #expect(snaps.allSatisfy { $0.source == .backfill })
    }

    @Test func backfillMarkerSkipsSecondRun() async throws {
        let container = AppContainerController.makePreview()
        await container.bootstrap()
        let ctx = container.modelContainer.mainContext

        seedAccountWithRecentTransactions(into: ctx, budgetId: "b1")
        try ctx.save()

        container.syncCoordinator.runHistoryBackfillIfNeeded(budgetId: "b1")
        let firstCount = try ctx.fetch(FetchDescriptor<DurableNetWorthSnapshot>()).count

        let settings = try #require(try ctx.fetch(FetchDescriptor<DurableUserSettings>()).first)
        #expect(settings.historyBackfillVersion == SyncCoordinator.currentHistoryBackfillVersion)

        container.syncCoordinator.runHistoryBackfillIfNeeded(budgetId: "b1")
        let secondCount = try ctx.fetch(FetchDescriptor<DurableNetWorthSnapshot>()).count
        #expect(secondCount == firstCount)
    }

    @Test func backfillCollapsesPreSeededDuplicateDay() async throws {
        let container = AppContainerController.makePreview()
        await container.bootstrap()
        let ctx = container.modelContainer.mainContext

        seedAccountWithRecentTransactions(into: ctx, budgetId: "b1")

        // Pre-seed a duplicate `.backfill` row from a hypothetical interrupted
        // prior run for a day inside the reconstruction window.
        let cal = Calendar(identifier: .gregorian)
        let day = cal.startOfDay(for: cal.date(byAdding: .day, value: -10, to: .now)!)
        ctx.insert(DurableNetWorthSnapshot(
            date: day,
            assetsMilliunits: 1_000_000,
            liabilitiesMilliunits: 0,
            source: .backfill
        ))
        try ctx.save()

        container.syncCoordinator.runHistoryBackfillIfNeeded(budgetId: "b1")

        let snaps = try ctx.fetch(FetchDescriptor<DurableNetWorthSnapshot>())
        let byDay = Dictionary(grouping: snaps) { cal.startOfDay(for: $0.date) }
        #expect(byDay.allSatisfy { $0.value.count == 1 })
    }

    @Test func dedupePreservesRicherLiveSnapshot() async throws {
        let container = AppContainerController.makePreview()
        await container.bootstrap()
        let ctx = container.modelContainer.mainContext

        seedAccountWithRecentTransactions(into: ctx, budgetId: "b1")

        // Pre-seed a `.live` snapshot for a specific day inside the window with
        // a much richer assets total (simulating a day where manual assets had
        // already been counted).
        let cal = Calendar(identifier: .gregorian)
        let day = cal.startOfDay(for: cal.date(byAdding: .day, value: -10, to: .now)!)
        let liveAssets: Int64 = 999_999_999_000  // far richer than reconstruction
        let liveSnap = DurableNetWorthSnapshot(
            date: day,
            assetsMilliunits: liveAssets,
            liabilitiesMilliunits: 0,
            source: .live
        )
        ctx.insert(liveSnap)
        try ctx.save()

        container.syncCoordinator.runHistoryBackfillIfNeeded(budgetId: "b1")

        let snaps = try ctx.fetch(FetchDescriptor<DurableNetWorthSnapshot>(
            predicate: #Predicate { $0.date == day }
        ))
        #expect(snaps.count == 1)
        let survivor = try #require(snaps.first)
        #expect(survivor.source == .live)
        #expect(survivor.assetsMilliunits == liveAssets)
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
