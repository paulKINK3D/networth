import Foundation
import Money

/// Projection of a single credit card's next statement.
public struct StatementProjection: Sendable, Hashable, Codable, Identifiable {
    public var id: String { cardAccountId }
    public let cardAccountId: String
    public let cardName: String
    /// Reference date used to compute the projection.
    public let asOf: Date
    public let lastCloseDate: Date
    public let nextCloseDate: Date
    /// Positive value representing what is owed today.
    public let currentBalanceOwed: Money
    public let scheduledChargesBeforeClose: Money
    public let scheduledPaymentsBeforeClose: Money
    /// Extrapolated charges between today and the next close, derived from
    /// recent historical spend on this card. Zero when no history is provided.
    public let projectedVariableCharges: Money
    /// Average daily charge on this card over the lookback window.
    public let dailyAverageCharge: Money
    public let projectedStatementBalance: Money
    public let minimumPayment: Money

    public init(
        cardAccountId: String,
        cardName: String,
        asOf: Date,
        lastCloseDate: Date,
        nextCloseDate: Date,
        currentBalanceOwed: Money,
        scheduledChargesBeforeClose: Money,
        scheduledPaymentsBeforeClose: Money,
        projectedVariableCharges: Money = .zero,
        dailyAverageCharge: Money = .zero,
        projectedStatementBalance: Money,
        minimumPayment: Money
    ) {
        self.cardAccountId = cardAccountId
        self.cardName = cardName
        self.asOf = asOf
        self.lastCloseDate = lastCloseDate
        self.nextCloseDate = nextCloseDate
        self.currentBalanceOwed = currentBalanceOwed
        self.scheduledChargesBeforeClose = scheduledChargesBeforeClose
        self.scheduledPaymentsBeforeClose = scheduledPaymentsBeforeClose
        self.projectedVariableCharges = projectedVariableCharges
        self.dailyAverageCharge = dailyAverageCharge
        self.projectedStatementBalance = projectedStatementBalance
        self.minimumPayment = minimumPayment
    }
}

public enum PayoffMode: String, Sendable, Hashable, Codable, CaseIterable {
    case full
    case minimum
    case custom
}

public struct PayoffScenario: Sendable, Hashable, Codable {
    public let mode: PayoffMode
    public let paymentAmount: Money
    public let carryover: Money

    public init(mode: PayoffMode, paymentAmount: Money, carryover: Money) {
        self.mode = mode
        self.paymentAmount = paymentAmount
        self.carryover = carryover
    }
}

/// A daily point on a forward cash-position projection (Projections tab).
public struct CashPositionPoint: Sendable, Hashable, Codable, Identifiable {
    public var id: Date { date }
    public let date: Date
    public let balance: Money

    public init(date: Date, balance: Money) {
        self.date = date
        self.balance = balance
    }
}

public struct CashProjectionEvent: Sendable, Hashable, Codable, Identifiable {
    public enum Kind: String, Sendable, Hashable, Codable {
        case scheduledIncome
        case scheduledExpense
        case transferIn
        case transferOut
        case cardPayment
    }

    public let id: String
    public let date: Date
    /// Signed from the selected cash pool's perspective.
    public let amount: Money
    public let kind: Kind
    public let title: String
    public let accountId: String?
    public let cardAccountId: String?

    public init(
        id: String,
        date: Date,
        amount: Money,
        kind: Kind,
        title: String,
        accountId: String? = nil,
        cardAccountId: String? = nil
    ) {
        self.id = id
        self.date = date
        self.amount = amount
        self.kind = kind
        self.title = title
        self.accountId = accountId
        self.cardAccountId = cardAccountId
    }
}

/// Extra cash capacity now after preserving the user's buffer and every
/// obligation already included across the full projected horizon.
public struct SafeToSpendEstimate: Sendable, Hashable {
    public let amount: Money
    public let lowPointDate: Date
    public let projectedLowBalance: Money
    public let minimumCashBuffer: Money
    public let startingBalance: Money
    public let knownInflows: Money
    public let scheduledOutflows: Money
    public let cardPaymentOutflows: Money
    public let expectedSpendingReserve: Money
    public let contributingEvents: [CashProjectionEvent]

    public init(
        amount: Money,
        lowPointDate: Date,
        projectedLowBalance: Money,
        minimumCashBuffer: Money,
        startingBalance: Money,
        knownInflows: Money,
        scheduledOutflows: Money,
        cardPaymentOutflows: Money,
        expectedSpendingReserve: Money,
        contributingEvents: [CashProjectionEvent]
    ) {
        self.amount = amount
        self.lowPointDate = lowPointDate
        self.projectedLowBalance = projectedLowBalance
        self.minimumCashBuffer = minimumCashBuffer
        self.startingBalance = startingBalance
        self.knownInflows = knownInflows
        self.scheduledOutflows = scheduledOutflows
        self.cardPaymentOutflows = cardPaymentOutflows
        self.expectedSpendingReserve = expectedSpendingReserve
        self.contributingEvents = contributingEvents
    }

    public var bufferGap: Money {
        max(minimumCashBuffer - projectedLowBalance, .zero)
    }
}

/// Known-commitment trajectory for one selected cash account. Expected ordinary
/// spending remains a pool-level estimate because it cannot be assigned to a
/// specific funding account with the same confidence as dated transactions.
public struct CashAccountProjection: Sendable, Hashable, Codable, Identifiable {
    public var id: String { accountId }
    public let accountId: String
    public let accountName: String
    public let startingBalance: Money
    public let points: [CashPositionPoint]
    public let lowPoint: CashPositionPoint
    public let firstShortfallPoint: CashPositionPoint?
    public let projectedShortfallLowPoint: CashPositionPoint?
    public let lowPointEvent: CashProjectionEvent?
    public let fundsCardPayments: Bool

    public init(
        accountId: String,
        accountName: String,
        startingBalance: Money,
        points: [CashPositionPoint],
        lowPoint: CashPositionPoint,
        firstShortfallPoint: CashPositionPoint?,
        projectedShortfallLowPoint: CashPositionPoint?,
        lowPointEvent: CashProjectionEvent?,
        fundsCardPayments: Bool
    ) {
        self.accountId = accountId
        self.accountName = accountName
        self.startingBalance = startingBalance
        self.points = points
        self.lowPoint = lowPoint
        self.firstShortfallPoint = firstShortfallPoint
        self.projectedShortfallLowPoint = projectedShortfallLowPoint
        self.lowPointEvent = lowPointEvent
        self.fundsCardPayments = fundsCardPayments
    }

    public var fundingNeeded: Money {
        max(-(projectedShortfallLowPoint?.balance ?? .zero), .zero)
    }
}

public struct MonthlySpendTransaction: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let date: Date
    public let payeeName: String
    public let amount: Money
    public let excluded: Bool

    public init(id: String, date: Date, payeeName: String, amount: Money, excluded: Bool) {
        self.id = id
        self.date = date
        self.payeeName = payeeName
        self.amount = amount
        self.excluded = excluded
    }
}

public struct MonthlySpendCategory: Sendable, Hashable, Codable, Identifiable {
    public var id: String { categoryId }
    public let categoryId: String
    public let categoryName: String
    public let amount: Money
    public let transactions: [MonthlySpendTransaction]

    public init(
        categoryId: String,
        categoryName: String,
        amount: Money,
        transactions: [MonthlySpendTransaction]
    ) {
        self.categoryId = categoryId
        self.categoryName = categoryName
        self.amount = amount
        self.transactions = transactions
    }
}

public struct MonthlySpendSample: Sendable, Hashable, Codable, Identifiable {
    public var id: Date { month }
    public let month: Date
    public let totalAmount: Money
    public let scheduledAmount: Money
    public let unscheduledAmount: Money
    public let categories: [MonthlySpendCategory]

    public init(
        month: Date,
        totalAmount: Money,
        scheduledAmount: Money,
        unscheduledAmount: Money,
        categories: [MonthlySpendCategory]
    ) {
        self.month = month
        self.totalAmount = totalAmount
        self.scheduledAmount = scheduledAmount
        self.unscheduledAmount = unscheduledAmount
        self.categories = categories
    }
}

public struct ExpectedSpendEstimate: Sendable, Hashable, Codable {
    public let dailyAmount: Money
    public let estimatedMonthlyAmount: Money
    public let unscheduledMonthlyAmount: Money
    public let higherSpendMonthlyAmount: Money?
    public let higherUnscheduledMonthlyAmount: Money?
    public let higherDailyAmount: Money?
    public let sampleMonthCount: Int
    public let historicalOutflows: Money
    public let scheduledOutflows: Money
    public let historyDays: Int
    public let lookbackStart: Date?
    public let monthlySamples: [MonthlySpendSample]

    public var scheduledMonthlyAmount: Money {
        max(estimatedMonthlyAmount - unscheduledMonthlyAmount, .zero)
    }

    public init(
        dailyAmount: Money,
        estimatedMonthlyAmount: Money = .zero,
        unscheduledMonthlyAmount: Money = .zero,
        higherSpendMonthlyAmount: Money? = nil,
        higherUnscheduledMonthlyAmount: Money? = nil,
        higherDailyAmount: Money? = nil,
        sampleMonthCount: Int = 0,
        historicalOutflows: Money,
        scheduledOutflows: Money,
        historyDays: Int,
        lookbackStart: Date?,
        monthlySamples: [MonthlySpendSample] = []
    ) {
        self.dailyAmount = dailyAmount
        self.estimatedMonthlyAmount = estimatedMonthlyAmount
        self.unscheduledMonthlyAmount = unscheduledMonthlyAmount
        self.higherSpendMonthlyAmount = higherSpendMonthlyAmount
        self.higherUnscheduledMonthlyAmount = higherUnscheduledMonthlyAmount
        self.higherDailyAmount = higherDailyAmount
        self.sampleMonthCount = sampleMonthCount
        self.historicalOutflows = historicalOutflows
        self.scheduledOutflows = scheduledOutflows
        self.historyDays = historyDays
        self.lookbackStart = lookbackStart
        self.monthlySamples = monthlySamples
    }

    public static let empty = ExpectedSpendEstimate(
        dailyAmount: .zero,
        estimatedMonthlyAmount: .zero,
        unscheduledMonthlyAmount: .zero,
        sampleMonthCount: 0,
        historicalOutflows: .zero,
        scheduledOutflows: .zero,
        historyDays: 0,
        lookbackStart: nil,
        monthlySamples: []
    )
}

public enum CashProjectionStatus: String, Sendable, Hashable, Codable {
    case covered
    case tight
    case shortfall
}
