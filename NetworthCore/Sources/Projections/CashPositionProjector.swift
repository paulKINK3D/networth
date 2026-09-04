import Foundation
import Money
import Models

/// Builds an explainable daily outlook for a user-selected cash pool.
public struct CashPositionProjector: Sendable {
    public let calendar: Calendar

    public init(calendar: Calendar = Calendar(identifier: .gregorian)) {
        self.calendar = calendar
    }

    private struct CategoryAccumulator {
        let name: String
        var amount: Money
        var transactions: [MonthlySpendTransaction]
    }

    public struct Result: Sendable, Hashable {
        public let startingBalance: Money
        public let knownPoints: [CashPositionPoint]
        public let expectedPoints: [CashPositionPoint]
        public let higherSpendPoints: [CashPositionPoint]
        public let events: [CashProjectionEvent]
        public let accountProjections: [CashAccountProjection]
        public let expectedSpend: ExpectedSpendEstimate
        public let knownLowPoint: CashPositionPoint?
        public let expectedLowPoint: CashPositionPoint?
        public let lowPointEvent: CashProjectionEvent?
        public let safeToSpend: SafeToSpendEstimate?
        public let higherSpendSafeToSpend: SafeToSpendEstimate?
        public let status: CashProjectionStatus
        public let horizonEnd: Date

        public var hasExpectedSpending: Bool { !expectedSpend.dailyAmount.isZero }
        public var knownFirstShortfallPoint: CashPositionPoint? {
            knownPoints.first { $0.balance < .zero }
        }
        public var expectedFirstShortfallPoint: CashPositionPoint? {
            expectedPoints.first { $0.balance < .zero }
        }
        public var knownFirstShortfallEvent: CashProjectionEvent? {
            firstNegativeEvent(on: knownFirstShortfallPoint?.date)
        }
        public var expectedFirstShortfallEvent: CashProjectionEvent? {
            firstNegativeEvent(on: expectedFirstShortfallPoint?.date)
        }
        public var knownInflows: Money {
            events.filter { $0.amount > .zero }.map(\.amount).sum()
        }
        public var scheduledOutflows: Money {
            events
                .filter { $0.amount.isNegative && $0.kind != .cardPayment }
                .map { $0.amount.absolute }
                .sum()
        }
        public var cardPaymentOutflows: Money {
            events
                .filter { $0.kind == .cardPayment }
                .map { $0.amount.absolute }
                .sum()
        }
        public var expectedSpendingReserve: Money {
            let knownEnding = knownPoints.last?.balance ?? startingBalance
            let expectedEnding = expectedPoints.last?.balance ?? startingBalance
            return max(knownEnding - expectedEnding, .zero)
        }
        public var projectedEndingBalance: Money {
            expectedPoints.last?.balance ?? startingBalance
        }
        public var accountShortfalls: [CashAccountProjection] {
            accountProjections
                .filter { $0.firstShortfallPoint != nil }
                .sorted { lhs, rhs in
                    let lhsDate = lhs.firstShortfallPoint?.date ?? .distantFuture
                    let rhsDate = rhs.firstShortfallPoint?.date ?? .distantFuture
                    if lhsDate != rhsDate { return lhsDate < rhsDate }
                    if lhs.fundsCardPayments != rhs.fundsCardPayments {
                        return lhs.fundsCardPayments
                    }
                    return lhs.fundingNeeded > rhs.fundingNeeded
                }
        }
        public var paymentAccountShortfalls: [CashAccountProjection] {
            accountShortfalls.filter(\.fundsCardPayments)
        }

        private func firstNegativeEvent(on date: Date?) -> CashProjectionEvent? {
            guard let date else { return nil }
            return events
                .filter { $0.date == date && $0.amount.isNegative }
                .min { $0.amount < $1.amount }
        }
    }

    public func project(
        cashAccounts: [AccountSnapshot],
        selectedCashAccountIds: Set<String>,
        cardAccountIds: Set<String>,
        fundedCardAccountIds: Set<String>,
        cardPayments: [UpcomingCardPayment],
        scheduled: [ScheduledTransactionSummary],
        /// Scheduled ids whose actuals never enter projection history
        /// (transfers, investment contributions): dated events only, never
        /// subtracted from the ordinary-spending estimate.
        estimateExemptScheduledIds: Set<String> = [],
        historicalTransactions: [TransactionSummary],
        excludedCategoryIds: Set<String> = [],
        excludedTransactionIds: Set<String> = [],
        /// Historical actuals already represented by dated recurring
        /// expectations. They remain visible in observed spending but are
        /// removed from the everyday reserve.
        recurringMatchedTransactionIds: Set<String> = [],
        outflowOnlyExcludedCategoryIds: Set<String> = [],
        spendAccountIds: Set<String> = [],
        lookbackDays: Int = 365,
        asOf today: Date,
        horizonDays: Int = 90,
        minimumCashBuffer: Money = Money.dollars(500),
        spendingReserve: Money = .zero
    ) -> Result {
        let start = calendar.startOfDay(for: today)
        let end = calendar.date(byAdding: .day, value: max(1, horizonDays), to: start) ?? start
        let accountsById = Dictionary(uniqueKeysWithValues: cashAccounts.map { ($0.id, $0) })
        let startingBalance = selectedCashAccountIds.compactMap { accountsById[$0]?.balance }.sum()
        let protectedSpendingReserve = max(spendingReserve, .zero)
        let protectedCashMinimum = minimumCashBuffer
            + protectedSpendingReserve

        let scheduledEvents = buildScheduledEvents(
            scheduled: scheduled,
            selectedCashAccountIds: selectedCashAccountIds,
            cardAccountIds: cardAccountIds,
            accountNames: accountsById.mapValues(\.name),
            start: start,
            end: end
        )
        let paymentEvents = cardPayments
            .filter { selectedCashAccountIds.contains($0.paymentAccountId) && $0.dueDate > start && $0.dueDate <= end }
            .map { payment in
                CashProjectionEvent(
                    id: payment.id,
                    date: calendar.startOfDay(for: payment.dueDate),
                    amount: -payment.amount,
                    kind: .cardPayment,
                    title: "\(payment.cardName) autopay",
                    accountId: payment.paymentAccountId,
                    cardAccountId: payment.cardAccountId
                )
            }
        let events = (scheduledEvents.pool + paymentEvents).sorted { lhs, rhs in
            lhs.date == rhs.date ? lhs.id < rhs.id : lhs.date < rhs.date
        }
        let accountEvents = scheduledEvents.accounts + paymentEvents

        let spendEstimate = estimateExpectedSpend(
            selectedCashAccountIds: selectedCashAccountIds,
            fundedCardAccountIds: fundedCardAccountIds,
            scheduled: scheduled,
            estimateExemptScheduledIds: estimateExemptScheduledIds,
            historicalTransactions: historicalTransactions,
            excludedCategoryIds: excludedCategoryIds,
            excludedTransactionIds: excludedTransactionIds,
            recurringMatchedTransactionIds: recurringMatchedTransactionIds,
            outflowOnlyExcludedCategoryIds: outflowOnlyExcludedCategoryIds,
            spendAccountIds: spendAccountIds,
            lookbackDays: lookbackDays,
            asOf: start
        )

        let eventsByDay = Dictionary(grouping: events) { calendar.startOfDay(for: $0.date) }
        var known = startingBalance
        var expected = startingBalance
        var knownPoints: [CashPositionPoint] = []
        var expectedPoints: [CashPositionPoint] = []
        var higherSpendPoints: [CashPositionPoint] = []
        var higherExpected = startingBalance
        var cursor = start

        while cursor <= end {
            if cursor > start {
                for event in eventsByDay[cursor] ?? [] {
                    known += event.amount
                    expected += event.amount
                    higherExpected += event.amount
                }
                expected -= spendEstimate.dailyAmount
                if let higherDailyAmount = spendEstimate.higherDailyAmount {
                    higherExpected -= higherDailyAmount
                }
            }
            knownPoints.append(CashPositionPoint(date: cursor, balance: known))
            expectedPoints.append(CashPositionPoint(date: cursor, balance: expected))
            if spendEstimate.higherDailyAmount != nil {
                higherSpendPoints.append(CashPositionPoint(date: cursor, balance: higherExpected))
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }

        let knownLow = knownPoints.min { $0.balance < $1.balance }
        let expectedLow = expectedPoints.min { $0.balance < $1.balance }
        let status: CashProjectionStatus
        if let expectedLow, expectedLow.balance < .zero {
            status = .shortfall
        } else if let expectedLow,
                  expectedLow.balance < protectedCashMinimum {
            status = .tight
        } else {
            status = .covered
        }
        let cause = expectedLow.flatMap { low in
            eventsByDay[calendar.startOfDay(for: low.date)]?
                .filter { $0.amount.isNegative }
                .min { $0.amount < $1.amount }
        }
        let safeToSpend = makeSafeToSpendEstimate(
            startingBalance: startingBalance,
            knownPoints: knownPoints,
            expectedPoints: expectedPoints,
            events: events,
            minimumCashBuffer: minimumCashBuffer,
            spendingReserve: protectedSpendingReserve
        )
        let higherSpendSafeToSpend = makeSafeToSpendEstimate(
            startingBalance: startingBalance,
            knownPoints: knownPoints,
            expectedPoints: higherSpendPoints,
            events: events,
            minimumCashBuffer: minimumCashBuffer,
            spendingReserve: protectedSpendingReserve
        )
        let accountProjections = buildAccountProjections(
            accountsById: accountsById,
            selectedCashAccountIds: selectedCashAccountIds,
            paymentAccountIds: Set(paymentEvents.compactMap(\.accountId)),
            events: accountEvents,
            start: start,
            end: end
        )

        return Result(
            startingBalance: startingBalance,
            knownPoints: knownPoints,
            expectedPoints: expectedPoints,
            higherSpendPoints: higherSpendPoints,
            events: events,
            accountProjections: accountProjections,
            expectedSpend: spendEstimate,
            knownLowPoint: knownLow,
            expectedLowPoint: expectedLow,
            lowPointEvent: cause,
            safeToSpend: safeToSpend,
            higherSpendSafeToSpend: higherSpendSafeToSpend,
            status: status,
            horizonEnd: end
        )
    }

    private func makeSafeToSpendEstimate(
        startingBalance: Money,
        knownPoints: [CashPositionPoint],
        expectedPoints: [CashPositionPoint],
        events: [CashProjectionEvent],
        minimumCashBuffer: Money,
        spendingReserve: Money
    ) -> SafeToSpendEstimate? {
        guard let lowPoint = expectedPoints.min(by: { $0.balance < $1.balance }) else {
            return nil
        }
        let contributingEvents = events.filter { $0.date <= lowPoint.date }
        let knownBalance = knownPoints.first(where: { $0.date == lowPoint.date })?.balance
            ?? startingBalance
        let knownInflows = contributingEvents
            .filter { $0.amount > .zero }
            .map(\.amount)
            .sum()
        let scheduledOutflows = contributingEvents
            .filter { $0.amount.isNegative && $0.kind != .cardPayment }
            .map { $0.amount.absolute }
            .sum()
        let cardPaymentOutflows = contributingEvents
            .filter { $0.kind == .cardPayment }
            .map { $0.amount.absolute }
            .sum()

        return SafeToSpendEstimate(
            amount: max(
                lowPoint.balance - minimumCashBuffer - spendingReserve,
                .zero
            ),
            lowPointDate: lowPoint.date,
            projectedLowBalance: lowPoint.balance,
            minimumCashBuffer: minimumCashBuffer,
            spendingReserve: spendingReserve,
            startingBalance: startingBalance,
            knownInflows: knownInflows,
            scheduledOutflows: scheduledOutflows,
            cardPaymentOutflows: cardPaymentOutflows,
            expectedSpendingReserve: max(knownBalance - lowPoint.balance, .zero),
            contributingEvents: contributingEvents
        )
    }

    private struct ScheduledEvents {
        var pool: [CashProjectionEvent] = []
        var accounts: [CashProjectionEvent] = []
    }

    private func buildScheduledEvents(
        scheduled: [ScheduledTransactionSummary],
        selectedCashAccountIds: Set<String>,
        cardAccountIds: Set<String>,
        accountNames: [String: String],
        start: Date,
        end: Date
    ) -> ScheduledEvents {
        guard let firstFutureDay = calendar.date(byAdding: .day, value: 1, to: start) else {
            return ScheduledEvents()
        }
        var result = ScheduledEvents()

        for item in scheduled where !item.deleted {
            let sourceSelected = selectedCashAccountIds.contains(item.accountId)
            let destinationSelected = item.transferAccountId.map(selectedCashAccountIds.contains) ?? false
            guard sourceSelected || destinationSelected else { continue }

            // Full-statement card events are generated independently and are
            // authoritative over YNAB's scheduled transfer amount.
            if cardAccountIds.contains(item.accountId) ||
                item.transferAccountId.map(cardAccountIds.contains) == true {
                continue
            }
            let signedAmount = sourceSelected ? item.amount : -item.amount
            let kind: CashProjectionEvent.Kind
            if item.transferAccountId != nil {
                kind = signedAmount.isNegative ? .transferOut : .transferIn
            } else {
                kind = signedAmount.isNegative ? .scheduledExpense : .scheduledIncome
            }
            let fallback = signedAmount.isNegative ? "Scheduled expense" : "Scheduled income"
            let title = item.payeeName?.isEmpty == false
                ? item.payeeName!
                : (item.transferAccountId.flatMap { accountNames[$0] } ?? fallback)

            for occurrence in item.occurrences(from: firstFutureDay, through: end, calendar: calendar) {
                let eventId = "scheduled:\(item.id):\(Int(occurrence.timeIntervalSince1970))"
                let eventDate = calendar.startOfDay(for: occurrence)

                if !(sourceSelected && destinationSelected) {
                    result.pool.append(CashProjectionEvent(
                        id: eventId,
                        date: eventDate,
                        amount: signedAmount,
                        kind: kind,
                        title: title,
                        accountId: sourceSelected ? item.accountId : item.transferAccountId,
                        source: item.source,
                        sourceID: item.sourceID
                    ))
                }

                if sourceSelected {
                    let sourceTitle = item.transferAccountId.flatMap { accountNames[$0] }
                        .map { "Transfer to \($0)" } ?? title
                    result.accounts.append(CashProjectionEvent(
                        id: "\(eventId):\(item.accountId)",
                        date: eventDate,
                        amount: item.amount,
                        kind: item.transferAccountId == nil
                            ? (item.amount.isNegative ? .scheduledExpense : .scheduledIncome)
                            : (item.amount.isNegative ? .transferOut : .transferIn),
                        title: sourceTitle,
                        accountId: item.accountId,
                        source: item.source,
                        sourceID: item.sourceID
                    ))
                }
                if destinationSelected, let destinationId = item.transferAccountId {
                    let destinationAmount = -item.amount
                    let destinationTitle = accountNames[item.accountId]
                        .map { "Transfer from \($0)" } ?? title
                    result.accounts.append(CashProjectionEvent(
                        id: "\(eventId):\(destinationId)",
                        date: eventDate,
                        amount: destinationAmount,
                        kind: destinationAmount.isNegative ? .transferOut : .transferIn,
                        title: destinationTitle,
                        accountId: destinationId,
                        source: item.source,
                        sourceID: item.sourceID
                    ))
                }
            }
        }
        return result
    }

    private func buildAccountProjections(
        accountsById: [String: AccountSnapshot],
        selectedCashAccountIds: Set<String>,
        paymentAccountIds: Set<String>,
        events: [CashProjectionEvent],
        start: Date,
        end: Date
    ) -> [CashAccountProjection] {
        var eventsByAccount: [String: [CashProjectionEvent]] = [:]
        for event in events {
            guard let accountId = event.accountId, selectedCashAccountIds.contains(accountId) else { continue }
            eventsByAccount[accountId, default: []].append(event)
        }

        return selectedCashAccountIds.compactMap { accountId in
            guard let account = accountsById[accountId] else { return nil }
            let accountEvents = eventsByAccount[accountId] ?? []
            let eventsByDay = Dictionary(grouping: accountEvents) { calendar.startOfDay(for: $0.date) }
            var balance = account.balance
            var points: [CashPositionPoint] = []
            var cursor = start

            while cursor <= end {
                if cursor > start {
                    for event in eventsByDay[cursor] ?? [] {
                        balance += event.amount
                    }
                }
                points.append(CashPositionPoint(date: cursor, balance: balance))
                guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
                cursor = next
            }

            guard let lowPoint = points.min(by: { $0.balance < $1.balance }) else { return nil }
            let firstShortfall = points.dropFirst().first { point in
                guard point.balance < .zero else { return false }
                return eventsByDay[calendar.startOfDay(for: point.date)]?
                    .contains { $0.amount.isNegative } == true
            }
            let projectedLowPoint = firstShortfall.flatMap { firstShortfall in
                points
                    .filter { $0.date >= firstShortfall.date }
                    .min { $0.balance < $1.balance }
            }
            let cause = projectedLowPoint.flatMap { projectedLowPoint in
                eventsByDay[calendar.startOfDay(for: projectedLowPoint.date)]?
                .filter { $0.amount.isNegative }
                .min { $0.amount < $1.amount }
            }
            return CashAccountProjection(
                accountId: accountId,
                accountName: account.name,
                startingBalance: account.balance,
                points: points,
                lowPoint: lowPoint,
                firstShortfallPoint: firstShortfall,
                projectedShortfallLowPoint: projectedLowPoint,
                lowPointEvent: cause,
                fundsCardPayments: paymentAccountIds.contains(accountId)
            )
        }
        .sorted { $0.accountName.localizedCaseInsensitiveCompare($1.accountName) == .orderedAscending }
    }

    private func estimateExpectedSpend(
        selectedCashAccountIds: Set<String>,
        fundedCardAccountIds: Set<String>,
        scheduled: [ScheduledTransactionSummary],
        estimateExemptScheduledIds: Set<String>,
        historicalTransactions: [TransactionSummary],
        excludedCategoryIds: Set<String>,
        excludedTransactionIds: Set<String>,
        recurringMatchedTransactionIds: Set<String>,
        outflowOnlyExcludedCategoryIds: Set<String>,
        spendAccountIds: Set<String>,
        lookbackDays: Int,
        asOf today: Date
    ) -> ExpectedSpendEstimate {
        let requestedDays = max(1, lookbackDays)
        guard let requestedStart = calendar.date(byAdding: .day, value: -requestedDays, to: today) else {
            return .empty
        }
        let eligibleIds = selectedCashAccountIds.union(fundedCardAccountIds)
        guard !eligibleIds.isEmpty else { return .empty }

        func excluded(categoryId: String?, amount: Money) -> Bool {
            guard let categoryId else { return false }
            if excludedCategoryIds.contains(categoryId) { return true }
            return amount.isNegative && outflowOnlyExcludedCategoryIds.contains(categoryId)
        }

        var ordinaryHistoricalOutflows = Money.zero
        var recurringHistoricalOutflows = Money.zero
        var historicalRefunds = Money.zero
        var historicalByMonth: [Date: Money] = [:]
        var recurringByMonth: [Date: Money] = [:]
        var refundsByMonth: [Date: Money] = [:]
        var categoriesByMonth: [Date: [String: CategoryAccumulator]] = [:]
        var earliest: Date?

        func recordHistoricalOutflow(
            _ amount: Money,
            on date: Date,
            categoryId: String?,
            categoryName: String?,
            transactionId: String,
            payeeName: String?,
            isExcluded: Bool,
            isRecurring: Bool
        ) {
            let outflow = amount.absolute
            let sampleMonth = monthStart(for: date)
            let resolvedId = categoryId ?? "uncategorized"
            let resolvedName = categoryName?.isEmpty == false ? categoryName! : "Uncategorized"
            let resolvedPayee = payeeName?.isEmpty == false ? payeeName! : "Transaction"
            var categories = categoriesByMonth[sampleMonth] ?? [:]
            var accumulator = categories[resolvedId] ?? CategoryAccumulator(
                name: resolvedName,
                amount: .zero,
                transactions: []
            )
            accumulator.transactions.append(MonthlySpendTransaction(
                id: transactionId,
                date: date,
                payeeName: resolvedPayee,
                amount: outflow,
                excluded: isExcluded && !isRecurring,
                recurring: isRecurring
            ))
            if isRecurring {
                recurringHistoricalOutflows += outflow
                recurringByMonth[sampleMonth, default: .zero] += outflow
                accumulator.amount += outflow
                earliest = min(earliest ?? date, date)
            } else if !isExcluded {
                ordinaryHistoricalOutflows += outflow
                historicalByMonth[sampleMonth, default: .zero] += outflow
                accumulator.amount += outflow
                earliest = min(earliest ?? date, date)
            }
            categories[resolvedId] = accumulator
            categoriesByMonth[sampleMonth] = categories
        }

        func recordHistoricalRefund(
            _ amount: Money,
            on date: Date,
            categoryId: String?,
            categoryName: String?,
            transactionId: String,
            payeeName: String?,
            isExcluded: Bool
        ) {
            let refund = amount.absolute
            let sampleMonth = monthStart(for: date)
            let resolvedId = categoryId ?? "uncategorized"
            let resolvedName = categoryName?.isEmpty == false
                ? categoryName! : "Uncategorized"
            let resolvedPayee = payeeName?.isEmpty == false
                ? payeeName! : "Refund"
            var categories = categoriesByMonth[sampleMonth] ?? [:]
            var accumulator = categories[resolvedId] ?? CategoryAccumulator(
                name: resolvedName,
                amount: .zero,
                transactions: []
            )
            accumulator.transactions.append(MonthlySpendTransaction(
                id: transactionId,
                date: date,
                payeeName: resolvedPayee,
                amount: -refund,
                excluded: isExcluded
            ))
            if !isExcluded {
                historicalRefunds += refund
                refundsByMonth[sampleMonth, default: .zero] += refund
                accumulator.amount -= refund
                earliest = min(earliest ?? date, date)
            }
            categories[resolvedId] = accumulator
            categoriesByMonth[sampleMonth] = categories
        }

        for transaction in historicalTransactions where
            !transaction.deleted && eligibleIds.contains(transaction.accountId) &&
            transaction.date >= requestedStart && transaction.date < today {
            if transaction.isSplit {
                for leg in transaction.subtransactions where !leg.deleted {
                    if let transfer = leg.transferAccountId, spendAccountIds.contains(transfer) { continue }
                    if excluded(categoryId: leg.categoryId, amount: leg.amount) { continue }
                    if leg.amount.isNegative {
                        recordHistoricalOutflow(
                            leg.amount,
                            on: transaction.date,
                            categoryId: leg.categoryId,
                            categoryName: leg.categoryName,
                            transactionId: leg.id,
                            payeeName: leg.payeeName ?? transaction.payeeName,
                            isExcluded: excludedTransactionIds.contains(leg.id),
                            isRecurring: recurringMatchedTransactionIds.contains(leg.id)
                        )
                    } else if leg.amount > .zero,
                              (leg.forecastTreatment
                                ?? transaction.forecastTreatment) == .refund {
                        recordHistoricalRefund(
                            leg.amount,
                            on: transaction.date,
                            categoryId: leg.categoryId,
                            categoryName: leg.categoryName,
                            transactionId: leg.id,
                            payeeName: leg.payeeName ?? transaction.payeeName,
                            isExcluded: excludedTransactionIds.contains(leg.id)
                        )
                    }
                }
            } else if transaction.amount.isNegative {
                if let transfer = transaction.transferAccountId, spendAccountIds.contains(transfer) { continue }
                if excluded(categoryId: transaction.categoryId, amount: transaction.amount) { continue }
                recordHistoricalOutflow(
                    transaction.amount,
                    on: transaction.date,
                    categoryId: transaction.categoryId,
                    categoryName: transaction.categoryName,
                    transactionId: transaction.id,
                    payeeName: transaction.payeeName,
                    isExcluded: excludedTransactionIds.contains(transaction.id),
                    isRecurring: recurringMatchedTransactionIds.contains(transaction.id)
                )
            } else if transaction.amount > .zero,
                      transaction.forecastTreatment == .refund {
                if excluded(
                    categoryId: transaction.categoryId,
                    amount: transaction.amount
                ) { continue }
                recordHistoricalRefund(
                    transaction.amount,
                    on: transaction.date,
                    categoryId: transaction.categoryId,
                    categoryName: transaction.categoryName,
                    transactionId: transaction.id,
                    payeeName: transaction.payeeName,
                    isExcluded: excludedTransactionIds.contains(transaction.id)
                )
            }
        }
        guard let earliest else { return .empty }

        var scheduledOutflows = Money.zero
        var scheduledByMonth: [Date: Money] = [:]
        // Exempt items exist as dated events only: their actuals never enter
        // the historical estimate (transfers, investment contributions), so
        // subtracting their occurrences would understate ordinary spending.
        for item in scheduled where !item.deleted
            && !estimateExemptScheduledIds.contains(item.id)
            && eligibleIds.contains(item.accountId)
            && item.amount.isNegative {
            if let transfer = item.transferAccountId, spendAccountIds.contains(transfer) { continue }
            if excluded(categoryId: item.categoryId, amount: item.amount) { continue }
            for occurrence in item.occurrences(from: earliest, through: today, calendar: calendar)
            where occurrence < today {
                let outflow = item.amount.absolute
                scheduledOutflows += outflow
                scheduledByMonth[monthStart(for: occurrence), default: .zero] += outflow
            }
        }

        let netOrdinaryHistoricalOutflows = max(
            ordinaryHistoricalOutflows - historicalRefunds,
            .zero
        )
        let historicalOutflows = netOrdinaryHistoricalOutflows
            + recurringHistoricalOutflows
        let theoreticalScheduledOutflows = min(
            scheduledOutflows, netOrdinaryHistoricalOutflows
        )
        let reportedScheduledOutflows = recurringHistoricalOutflows
            + theoreticalScheduledOutflows
        let unscheduled = max(
            netOrdinaryHistoricalOutflows - theoreticalScheduledOutflows,
            .zero
        )
        let days = max(1, calendar.dateComponents([.day], from: calendar.startOfDay(for: earliest), to: today).day ?? 1)
        let firstCompleteMonth = calendar.date(
            byAdding: .month,
            value: 1,
            to: monthStart(for: earliest)
        )
        let currentMonth = monthStart(for: today)
        var monthlyTotalSamples: [Money] = []
        var monthlyUnscheduledSamples: [Money] = []
        var monthlySamples: [MonthlySpendSample] = []
        var month = firstCompleteMonth
        while let sampleMonth = month, sampleMonth < currentMonth {
            let ordinary = max(
                (historicalByMonth[sampleMonth] ?? .zero)
                    - (refundsByMonth[sampleMonth] ?? .zero),
                .zero
            )
            let recurring = recurringByMonth[sampleMonth] ?? .zero
            let scheduled = recurring
                + min(scheduledByMonth[sampleMonth] ?? .zero, ordinary)
            let unscheduled = ordinary
                - min(scheduledByMonth[sampleMonth] ?? .zero, ordinary)
            let historical = ordinary + recurring
            let categories = (categoriesByMonth[sampleMonth] ?? [:])
                .map { categoryId, accumulator in
                    MonthlySpendCategory(
                        categoryId: categoryId,
                        categoryName: accumulator.name,
                        amount: accumulator.amount,
                        transactions: accumulator.transactions.sorted { lhs, rhs in
                            if lhs.date != rhs.date { return lhs.date > rhs.date }
                            return lhs.payeeName.localizedCaseInsensitiveCompare(rhs.payeeName) == .orderedAscending
                        }
                    )
                }
                .sorted { lhs, rhs in
                    if lhs.amount != rhs.amount { return lhs.amount > rhs.amount }
                    return lhs.categoryName.localizedCaseInsensitiveCompare(rhs.categoryName) == .orderedAscending
                }
            monthlyTotalSamples.append(historical)
            monthlyUnscheduledSamples.append(unscheduled)
            monthlySamples.append(MonthlySpendSample(
                month: sampleMonth,
                totalAmount: historical,
                scheduledAmount: scheduled,
                unscheduledAmount: unscheduled,
                categories: categories
            ))
            month = calendar.date(byAdding: .month, value: 1, to: sampleMonth)
        }

        let estimatedMonthly: Money
        let unscheduledMonthly: Money
        let daily: Money
        var higherSpendMonthly: Money?
        var higherUnscheduledMonthly: Money?
        var higherDaily: Money?
        if monthlyTotalSamples.isEmpty {
            daily = Money(milliunits: unscheduled.milliunits / Int64(days))
            estimatedMonthly = Money(
                milliunits: historicalOutflows.milliunits * 365 / Int64(days) / 12
            )
            unscheduledMonthly = Money(
                milliunits: unscheduled.milliunits * 365 / Int64(days) / 12
            )
        } else {
            estimatedMonthly = BudgetDateMath.mean(of: monthlyTotalSamples)
            unscheduledMonthly = BudgetDateMath.mean(
                of: monthlyUnscheduledSamples
            )
            daily = Money(milliunits: unscheduledMonthly.milliunits * 12 / 365)
            if monthlyTotalSamples.count >= 4 {
                let candidateMonthly = upperQuartile(monthlyTotalSamples)
                let candidateUnscheduled = upperQuartile(monthlyUnscheduledSamples)
                let candidateDaily = Money(
                    milliunits: candidateUnscheduled.milliunits * 12 / 365
                )
                if candidateDaily > daily {
                    higherSpendMonthly = candidateMonthly
                    higherUnscheduledMonthly = candidateUnscheduled
                    higherDaily = candidateDaily
                }
            }
        }
        return ExpectedSpendEstimate(
            dailyAmount: daily,
            estimatedMonthlyAmount: estimatedMonthly,
            unscheduledMonthlyAmount: unscheduledMonthly,
            higherSpendMonthlyAmount: higherSpendMonthly,
            higherUnscheduledMonthlyAmount: higherUnscheduledMonthly,
            higherDailyAmount: higherDaily,
            sampleMonthCount: monthlyTotalSamples.count,
            historicalOutflows: historicalOutflows,
            historicalRefunds: historicalRefunds,
            scheduledOutflows: reportedScheduledOutflows,
            historyDays: days,
            lookbackStart: earliest,
            monthlySamples: monthlySamples
        )
    }

    private func monthStart(for date: Date) -> Date {
        let components = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: components).map(calendar.startOfDay(for:)) ?? calendar.startOfDay(for: date)
    }

    private func upperQuartile(_ values: [Money]) -> Money {
        guard !values.isEmpty else { return .zero }
        let sorted = values.sorted()
        let nearestRank = Int(ceil(Double(sorted.count) * 0.75))
        return sorted[max(0, nearestRank - 1)]
    }
}
