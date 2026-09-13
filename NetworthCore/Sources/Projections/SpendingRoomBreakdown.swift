import Foundation
import Money
import Models

/// Ledger derivation for the Spending Room detail: how starting cash reaches
/// the projected low, then how the low divides into protected cash and room.
public enum SpendingRoomLedger {
    public struct Entry: Sendable, Hashable, Identifiable {
        public enum Kind: String, Sendable {
            case startingCash
            case inflows
            case bills
            case cardAutopays
            case everydaySpending
            case projectedLow
        }

        public let kind: Kind
        /// Signed movement for flows; absolute level for start and low.
        public let amount: Money
        /// Vertical waterfall bar range; `barStart <= barEnd`.
        public let barStart: Money
        public let barEnd: Money

        public var id: String { kind.rawValue }
        public var isLevel: Bool {
            kind == .startingCash || kind == .projectedLow
        }

        public init(kind: Kind, amount: Money, barStart: Money, barEnd: Money) {
            self.kind = kind
            self.amount = amount
            self.barStart = min(barStart, barEnd)
            self.barEnd = max(barStart, barEnd)
        }
    }

    public struct Spendable: Sendable, Hashable {
        public let cashBuffer: Money
        public let reserves: Money
        public let room: Money
        public let protectedCashGap: Money
        public let projectedLowBalance: Money

        public var isCovered: Bool { protectedCashGap.isZero }

        public init(
            cashBuffer: Money,
            reserves: Money,
            room: Money,
            protectedCashGap: Money,
            projectedLowBalance: Money
        ) {
            self.cashBuffer = cashBuffer
            self.reserves = reserves
            self.room = room
            self.protectedCashGap = protectedCashGap
            self.projectedLowBalance = projectedLowBalance
        }
    }

    /// Ordered movements from starting cash down to the projected low. Zero
    /// movements are omitted; the start and low levels are always present.
    public static func cashFlowEntries(
        from estimate: SafeToSpendEstimate
    ) -> [Entry] {
        var entries: [Entry] = [
            Entry(
                kind: .startingCash,
                amount: estimate.startingBalance,
                barStart: .zero,
                barEnd: estimate.startingBalance
            )
        ]
        var running = estimate.startingBalance

        func appendMovement(_ kind: Entry.Kind, signed: Money) {
            guard !signed.isZero else { return }
            let next = running + signed
            entries.append(Entry(
                kind: kind,
                amount: signed,
                barStart: running,
                barEnd: next
            ))
            running = next
        }

        appendMovement(.inflows, signed: estimate.knownInflows)
        appendMovement(.bills, signed: -estimate.scheduledOutflows)
        appendMovement(.cardAutopays, signed: -estimate.cardPaymentOutflows)
        appendMovement(
            .everydaySpending,
            signed: -estimate.expectedSpendingReserve
        )
        entries.append(Entry(
            kind: .projectedLow,
            amount: estimate.projectedLowBalance,
            barStart: .zero,
            barEnd: estimate.projectedLowBalance
        ))
        return entries
    }

    public static func spendable(
        from estimate: SafeToSpendEstimate
    ) -> Spendable {
        Spendable(
            cashBuffer: estimate.minimumCashBuffer,
            reserves: estimate.spendingReserve,
            room: estimate.amount,
            protectedCashGap: estimate.protectedCashGap,
            projectedLowBalance: estimate.projectedLowBalance
        )
    }
}

/// Per-group averages of everyday spending, derived from the estimate's
/// complete-month samples. Recurring-matched actuals belong to Bills and
/// excluded lines are user decisions, so both stay out of the averages;
/// refunds arrive as negative lines and net against their group.
public enum SpendingRoomDrivers {
    public static let ungroupedId = "spending-room-ungrouped"

    public struct GroupSpending: Sendable, Hashable, Identifiable {
        public let id: String
        public let name: String
        public let monthlyAverage: Money

        public init(id: String, name: String, monthlyAverage: Money) {
            self.id = id
            self.name = name
            self.monthlyAverage = monthlyAverage
        }
    }

    public struct CategorySpending: Sendable, Hashable, Identifiable {
        public let id: String
        public let name: String
        public let monthlyAverage: Money

        public init(id: String, name: String, monthlyAverage: Money) {
            self.id = id
            self.name = name
            self.monthlyAverage = monthlyAverage
        }
    }

    public struct PayeeSpending: Sendable, Hashable, Identifiable {
        public let name: String
        public let monthlyAverage: Money
        /// Every non-recurring line for the payee, newest first, including
        /// excluded ones so the caller can offer include/exclude in place.
        public let transactions: [MonthlySpendTransaction]

        public var id: String { name }
        public var purchaseCount: Int {
            transactions.filter { !$0.excluded }.count
        }

        public init(
            name: String,
            monthlyAverage: Money,
            transactions: [MonthlySpendTransaction]
        ) {
            self.name = name
            self.monthlyAverage = monthlyAverage
            self.transactions = transactions
        }
    }

    /// Average monthly spending per group across the sampled complete months,
    /// largest first. Categories without a group land in one named bucket.
    public static func groupAverages(
        samples: [MonthlySpendSample],
        groupIdForCategory: (String) -> String?,
        nameForGroup: (String) -> String,
        ungroupedName: String = "Everything else"
    ) -> [GroupSpending] {
        guard !samples.isEmpty else { return [] }
        var totals: [String: Money] = [:]
        for sample in samples {
            for category in sample.categories {
                let groupId = groupIdForCategory(category.categoryId)
                    ?? ungroupedId
                for transaction in category.transactions
                where !transaction.excluded && !transaction.recurring {
                    totals[groupId, default: .zero] += transaction.amount
                }
            }
        }
        let monthCount = Int64(samples.count)
        return totals
            .map { groupId, total in
                GroupSpending(
                    id: groupId,
                    name: groupId == ungroupedId
                        ? ungroupedName
                        : nameForGroup(groupId),
                    monthlyAverage: Money(
                        milliunits: total.milliunits / monthCount
                    )
                )
            }
            .filter { $0.monthlyAverage > .zero }
            .sorted { lhs, rhs in
                if lhs.monthlyAverage != rhs.monthlyAverage {
                    return lhs.monthlyAverage > rhs.monthlyAverage
                }
                return lhs.name
                    .localizedCaseInsensitiveCompare(rhs.name)
                    == .orderedAscending
            }
    }

    /// Average monthly spending per category inside one group, largest first.
    public static func categoryAverages(
        groupId: String,
        samples: [MonthlySpendSample],
        groupIdForCategory: (String) -> String?
    ) -> [CategorySpending] {
        guard !samples.isEmpty else { return [] }
        var totals: [String: Money] = [:]
        var names: [String: String] = [:]
        for sample in samples {
            for category in sample.categories
            where (groupIdForCategory(category.categoryId) ?? ungroupedId)
                == groupId {
                names[category.categoryId] = category.categoryName
                for transaction in category.transactions
                where !transaction.excluded && !transaction.recurring {
                    totals[category.categoryId, default: .zero]
                        += transaction.amount
                }
            }
        }
        let monthCount = Int64(samples.count)
        return totals
            .map { categoryId, total in
                CategorySpending(
                    id: categoryId,
                    name: names[categoryId] ?? "Uncategorized",
                    monthlyAverage: Money(
                        milliunits: total.milliunits / monthCount
                    )
                )
            }
            .filter { $0.monthlyAverage > .zero }
            .sorted { lhs, rhs in
                if lhs.monthlyAverage != rhs.monthlyAverage {
                    return lhs.monthlyAverage > rhs.monthlyAverage
                }
                return lhs.name
                    .localizedCaseInsensitiveCompare(rhs.name)
                    == .orderedAscending
            }
    }

    /// This month's net everyday spending for one category, from the
    /// estimate's partial current-month sample.
    public static func currentMonthTotal(
        categoryId: String,
        currentMonth: MonthlySpendSample?
    ) -> Money {
        guard let sample = currentMonth else { return .zero }
        return sample.categories
            .filter { $0.categoryId == categoryId }
            .flatMap(\.transactions)
            .filter { !$0.excluded && !$0.recurring }
            .map(\.amount)
            .sum()
    }

    /// One category's payees across the sampled months, summed to one entry
    /// per payee, largest average first. Fully excluded payees stay listed so
    /// their lines can be re-included.
    public static func payeeSummaries(
        categoryId: String,
        samples: [MonthlySpendSample]
    ) -> [PayeeSpending] {
        guard !samples.isEmpty else { return [] }
        var transactionsByPayee: [String: [MonthlySpendTransaction]] = [:]
        for sample in samples {
            for category in sample.categories
            where category.categoryId == categoryId {
                for transaction in category.transactions
                where !transaction.recurring {
                    transactionsByPayee[transaction.payeeName, default: []]
                        .append(transaction)
                }
            }
        }
        let monthCount = Int64(samples.count)
        return transactionsByPayee
            .map { name, transactions in
                let total = transactions
                    .filter { !$0.excluded }
                    .map(\.amount)
                    .sum()
                return PayeeSpending(
                    name: name,
                    monthlyAverage: Money(
                        milliunits: total.milliunits / monthCount
                    ),
                    transactions: transactions.sorted { lhs, rhs in
                        if lhs.date != rhs.date { return lhs.date > rhs.date }
                        return lhs.id < rhs.id
                    }
                )
            }
            .sorted { lhs, rhs in
                if lhs.monthlyAverage != rhs.monthlyAverage {
                    return lhs.monthlyAverage > rhs.monthlyAverage
                }
                return lhs.name
                    .localizedCaseInsensitiveCompare(rhs.name)
                    == .orderedAscending
            }
    }
}

/// Aggregate card-cycle summary: closed statements awaiting autopay, the open
/// statements' posted charges so far, and the next simulated payments. Future
/// variable purchases stay excluded, matching the payment forecaster.
public enum SpendingRoomCardCycle {
    public struct Summary: Sendable, Hashable {
        public let closedTotal: Money
        public let closedCount: Int
        public let closedLatestDueDate: Date?
        public let openChargesSoFar: Money
        public let openEarliestCloseDate: Date?
        public let openLatestCloseDate: Date?
        /// Mean fraction of the current statement cycle already elapsed,
        /// across cards where both boundaries are known.
        public let cycleElapsedFraction: Double?
        public let nextPaymentsTotal: Money
        public let nextPaymentsCount: Int
        public let nextPaymentsLatestDueDate: Date?

        public var hasClosed: Bool { closedCount > 0 }
        public var hasNext: Bool { nextPaymentsCount > 0 }

        public init(
            closedTotal: Money,
            closedCount: Int,
            closedLatestDueDate: Date?,
            openChargesSoFar: Money,
            openEarliestCloseDate: Date?,
            openLatestCloseDate: Date?,
            cycleElapsedFraction: Double?,
            nextPaymentsTotal: Money,
            nextPaymentsCount: Int,
            nextPaymentsLatestDueDate: Date?
        ) {
            self.closedTotal = closedTotal
            self.closedCount = closedCount
            self.closedLatestDueDate = closedLatestDueDate
            self.openChargesSoFar = openChargesSoFar
            self.openEarliestCloseDate = openEarliestCloseDate
            self.openLatestCloseDate = openLatestCloseDate
            self.cycleElapsedFraction = cycleElapsedFraction
            self.nextPaymentsTotal = nextPaymentsTotal
            self.nextPaymentsCount = nextPaymentsCount
            self.nextPaymentsLatestDueDate = nextPaymentsLatestDueDate
        }
    }

    public static func summarize(
        payments: [UpcomingCardPayment],
        openChargesByCardId: [String: Money],
        asOf today: Date,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> Summary? {
        let closed = payments.filter { $0.basis == .closedStatementEstimate }
        let futureByCard = Dictionary(
            grouping: payments.filter { $0.basis == .futureScheduledOnly },
            by: \.cardAccountId
        ).compactMapValues { cardPayments in
            cardPayments.min { lhs, rhs in
                lhs.closeDate == rhs.closeDate
                    ? lhs.id < rhs.id
                    : lhs.closeDate < rhs.closeDate
            }
        }
        let openCharges = openChargesByCardId.values
            .map { max($0, .zero) }
            .sum()
        guard !closed.isEmpty || !futureByCard.isEmpty else { return nil }

        let nextPayments = futureByCard.values
        let start = calendar.startOfDay(for: today)
        let fractions: [Double] = closed.compactMap { payment in
            guard let next = futureByCard[payment.cardAccountId] else {
                return nil
            }
            let lastClose = calendar.startOfDay(for: payment.closeDate)
            let nextClose = calendar.startOfDay(for: next.closeDate)
            let cycleDays = calendar.dateComponents(
                [.day], from: lastClose, to: nextClose
            ).day ?? 0
            guard cycleDays > 0 else { return nil }
            let elapsed = calendar.dateComponents(
                [.day], from: lastClose, to: start
            ).day ?? 0
            return min(max(Double(elapsed) / Double(cycleDays), 0), 1)
        }

        return Summary(
            closedTotal: closed.map(\.amount).sum(),
            closedCount: closed.count,
            closedLatestDueDate: closed.map(\.dueDate).max(),
            openChargesSoFar: openCharges,
            openEarliestCloseDate: nextPayments.map(\.closeDate).min(),
            openLatestCloseDate: nextPayments.map(\.closeDate).max(),
            cycleElapsedFraction: fractions.isEmpty
                ? nil
                : fractions.reduce(0, +) / Double(fractions.count),
            nextPaymentsTotal: nextPayments.map(\.amount).sum(),
            nextPaymentsCount: nextPayments.count,
            nextPaymentsLatestDueDate: nextPayments.map(\.dueDate).max()
        )
    }
}
