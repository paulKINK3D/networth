import Foundation

/// One matched two-account movement: the outflow and inflow legs of a card
/// payment or internal transfer between monitored accounts. Pairing carries
/// the identity a single leg lacks — the twin's account names the movement.
public struct CounterpartPair: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case cardPayment
        case internalTransfer
    }

    public let outflowId: String
    public let inflowId: String
    public let kind: Kind

    public init(outflowId: String, inflowId: String, kind: Kind) {
        self.outflowId = outflowId
        self.inflowId = inflowId
        self.kind = kind
    }
}

/// The minimal transaction facts counterpart matching needs.
public struct CounterpartCandidate: Sendable, Hashable, Identifiable {
    public let id: String
    public let accountId: String
    public let amountMilliunits: Int64
    public let postedDate: Date
    /// Provider-default treatment (`TransactionClassifier.forecastTreatment`),
    /// before any prefill or user decision.
    public let providerDefaultTreatment: ForecastTreatment?

    public init(
        id: String,
        accountId: String,
        amountMilliunits: Int64,
        postedDate: Date,
        providerDefaultTreatment: ForecastTreatment?
    ) {
        self.id = id
        self.accountId = accountId
        self.amountMilliunits = amountMilliunits
        self.postedDate = postedDate
        self.providerDefaultTreatment = providerDefaultTreatment
    }
}

/// Pairs the two legs of transfers and card payments across monitored
/// accounts. Measured on real history: legs match to the penny, the card-side
/// credit posts up to a few days before the bank debit, and a five-day window
/// covers essentially every true pair — so matching requires exact amounts
/// and rejects anything without transfer-flavored provider evidence.
public struct TransferCounterpartMatcher: Sendable {
    public static let windowDays = 5

    private let calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    public func matches(
        candidates: [CounterpartCandidate],
        accountKinds: [String: FinancialAccountType]
    ) -> [CounterpartPair] {
        let monitored = candidates.filter {
            accountKinds[$0.accountId] != nil && $0.amountMilliunits != 0
        }
        let outflows = monitored.filter { $0.amountMilliunits < 0 }
        let inflows = monitored.filter { $0.amountMilliunits > 0 }
        guard !outflows.isEmpty, !inflows.isEmpty else { return [] }

        var viable: [(pair: CounterpartPair, gapDays: Int)] = []
        for outflow in outflows {
            for inflow in inflows {
                guard let match = pairKind(
                    outflow: outflow,
                    inflow: inflow,
                    accountKinds: accountKinds
                ) else { continue }
                viable.append(match)
            }
        }

        // One leg pairs with exactly one twin; closest posting gap wins so
        // recurring same-amount transfers stay inside their own week.
        viable.sort {
            if $0.gapDays != $1.gapDays { return $0.gapDays < $1.gapDays }
            if $0.pair.outflowId != $1.pair.outflowId {
                return $0.pair.outflowId < $1.pair.outflowId
            }
            return $0.pair.inflowId < $1.pair.inflowId
        }
        var usedIds: Set<String> = []
        var pairs: [CounterpartPair] = []
        for candidate in viable {
            guard !usedIds.contains(candidate.pair.outflowId),
                  !usedIds.contains(candidate.pair.inflowId)
            else { continue }
            usedIds.insert(candidate.pair.outflowId)
            usedIds.insert(candidate.pair.inflowId)
            pairs.append(candidate.pair)
        }
        return pairs
    }

    private func pairKind(
        outflow: CounterpartCandidate,
        inflow: CounterpartCandidate,
        accountKinds: [String: FinancialAccountType]
    ) -> (pair: CounterpartPair, gapDays: Int)? {
        guard outflow.accountId != inflow.accountId,
              inflow.amountMilliunits == -outflow.amountMilliunits
        else { return nil }

        let transferFlavored: Set<ForecastTreatment> = [
            .cardPayment, .internalTransfer
        ]
        guard outflow.providerDefaultTreatment.map(transferFlavored.contains)
            == true
            || inflow.providerDefaultTreatment.map(transferFlavored.contains)
            == true
        else { return nil }

        let gap = abs(calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: outflow.postedDate),
            to: calendar.startOfDay(for: inflow.postedDate)
        ).day ?? .max)
        guard gap <= Self.windowDays else { return nil }

        guard let outflowKind = accountKinds[outflow.accountId],
              let inflowKind = accountKinds[inflow.accountId]
        else { return nil }

        let kind: CounterpartPair.Kind
        if inflowKind == .creditCard, outflowKind.isCashLike {
            kind = .cardPayment
        } else if inflowKind.isCashLike, outflowKind.isCashLike {
            kind = .internalTransfer
        } else {
            return nil
        }
        return (
            CounterpartPair(
                outflowId: outflow.id,
                inflowId: inflow.id,
                kind: kind
            ),
            gap
        )
    }
}
