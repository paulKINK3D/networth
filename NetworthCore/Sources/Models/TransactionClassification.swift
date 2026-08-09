import Foundation
import Money

public struct HistoricalTransactionMatch: Identifiable, Hashable, Sendable {
    public let legacyTransactionId: String
    public let plaidTransactionId: String
    public let confidence: ClassificationConfidence
    public let score: Int
    public let isAutomatic: Bool

    public var id: String { "\(legacyTransactionId):\(plaidTransactionId)" }

    public init(
        legacyTransactionId: String,
        plaidTransactionId: String,
        confidence: ClassificationConfidence,
        score: Int,
        isAutomatic: Bool
    ) {
        self.legacyTransactionId = legacyTransactionId
        self.plaidTransactionId = plaidTransactionId
        self.confidence = confidence
        self.score = score
        self.isAutomatic = isAutomatic
    }
}

public struct HistoricalTransactionMatcher: Sendable {
    public init() {}

    public func matches(
        legacy: [TransactionSummary],
        plaid: [FinancialTransactionSummary],
        canonicalAccountIdByYNABId: [String: String],
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> [HistoricalTransactionMatch] {
        var legacyByAccountAndAmount: [MatchKey: [TransactionSummary]] = [:]
        for transaction in legacy where !transaction.deleted {
            guard let canonicalAccountID =
                    canonicalAccountIdByYNABId[transaction.accountId] else {
                continue
            }
            legacyByAccountAndAmount[
                MatchKey(
                    accountID: canonicalAccountID,
                    amountMilliunits: transaction.amount.milliunits
                ),
                default: []
            ].append(transaction)
        }
        let plaidGroups = Dictionary(
            grouping: plaid.filter { !$0.pending },
            by: {
                MatchKey(
                    accountID: $0.accountId,
                    amountMilliunits: $0.amount.milliunits
                )
            }
        )
        var results: [HistoricalTransactionMatch] = []
        for key in plaidGroups.keys.sorted(by: {
            if $0.accountID == $1.accountID {
                return $0.amountMilliunits < $1.amountMilliunits
            }
            return $0.accountID < $1.accountID
        }) {
            guard let plaidGroup = plaidGroups[key],
                  let legacyGroup = legacyByAccountAndAmount[key],
                  !legacyGroup.isEmpty else {
                continue
            }
            results.append(contentsOf: groupMatches(
                legacy: legacyGroup,
                plaid: plaidGroup,
                calendar: calendar
            ))
        }
        return results.sorted {
            if $0.plaidTransactionId == $1.plaidTransactionId {
                return $0.legacyTransactionId < $1.legacyTransactionId
            }
            return $0.plaidTransactionId < $1.plaidTransactionId
        }
    }

    private struct MatchKey: Hashable {
        let accountID: String
        let amountMilliunits: Int64
    }

    private struct Candidate {
        let transaction: TransactionSummary
        let score: Int
        let nameScore: Int
    }

    /// Maximum-cardinality bipartite assignment for one exact
    /// account-and-amount group. Constrained transactions are visited first,
    /// and score-ordered augmenting paths prevent an early row from consuming
    /// the only candidate available to a later row.
    private func groupMatches(
        legacy: [TransactionSummary],
        plaid: [FinancialTransactionSummary],
        calendar: Calendar
    ) -> [HistoricalTransactionMatch] {
        let orderedPlaid = plaid.sorted {
            ($0.postedDate, $0.id) < ($1.postedDate, $1.id)
        }
        var candidatesByPlaidID: [String: [Candidate]] = [:]
        var plaidByID: [String: FinancialTransactionSummary] = [:]
        for transaction in orderedPlaid {
            plaidByID[transaction.id] = transaction
            candidatesByPlaidID[transaction.id] = legacy.compactMap {
                legacyTransaction -> Candidate? in
                let dayDistance = plausibleDayDistance(
                    legacyDate: legacyTransaction.date,
                    plaidTransaction: transaction,
                    calendar: calendar
                )
                guard dayDistance <= 3 else { return nil }
                let nameScore = similarityScore(
                    legacyTransaction.payeeName ?? "",
                    transaction.fallbackDisplayName
                )
                return Candidate(
                    transaction: legacyTransaction,
                    score: max(1, 4 - dayDistance) + nameScore,
                    nameScore: nameScore
                )
            }.sorted {
                if $0.score == $1.score {
                    return $0.transaction.id < $1.transaction.id
                }
                return $0.score > $1.score
            }
        }

        let assignmentOrder = orderedPlaid.sorted {
            let lhsCount = candidatesByPlaidID[$0.id]?.count ?? 0
            let rhsCount = candidatesByPlaidID[$1.id]?.count ?? 0
            if lhsCount != rhsCount { return lhsCount < rhsCount }
            return ($0.postedDate, $0.id) < ($1.postedDate, $1.id)
        }
        var plaidIDByLegacyID: [String: String] = [:]
        var legacyIDByPlaidID: [String: String] = [:]

        func assign(
            plaidID: String,
            visitedLegacyIDs: inout Set<String>
        ) -> Bool {
            for candidate in candidatesByPlaidID[plaidID] ?? [] {
                let legacyID = candidate.transaction.id
                guard visitedLegacyIDs.insert(legacyID).inserted else {
                    continue
                }
                if let occupyingPlaidID = plaidIDByLegacyID[legacyID] {
                    if assign(
                        plaidID: occupyingPlaidID,
                        visitedLegacyIDs: &visitedLegacyIDs
                    ) {
                        plaidIDByLegacyID[legacyID] = plaidID
                        legacyIDByPlaidID[plaidID] = legacyID
                        return true
                    }
                } else {
                    plaidIDByLegacyID[legacyID] = plaidID
                    legacyIDByPlaidID[plaidID] = legacyID
                    return true
                }
            }
            return false
        }

        for transaction in assignmentOrder {
            var visited = Set<String>()
            _ = assign(
                plaidID: transaction.id,
                visitedLegacyIDs: &visited
            )
        }

        return orderedPlaid.compactMap { transaction in
            guard let legacyID = legacyIDByPlaidID[transaction.id],
                  let assigned = candidatesByPlaidID[transaction.id]?
                    .first(where: { $0.transaction.id == legacyID }) else {
                return nil
            }
            let alternatives = (candidatesByPlaidID[transaction.id] ?? [])
                .filter { $0.transaction.id != legacyID }
            let runnerUp = alternatives.first
            let assignedIsBest =
                candidatesByPlaidID[transaction.id]?.first?
                    .transaction.id == legacyID
            let isOnlyCandidate = runnerUp == nil
            let uniqueEnough = assignedIsBest
                && (isOnlyCandidate
                    || assigned.score - (runnerUp?.score ?? 0) >= 2)
            let equivalentOutcome = Set(
                (candidatesByPlaidID[transaction.id] ?? []).map {
                    classificationSignature($0.transaction)
                }
            ).count == 1
            let confidence: ClassificationConfidence =
                isOnlyCandidate || equivalentOutcome
                    ? .high
                    : uniqueEnough && assigned.nameScore == 4
                        ? .high
                        : assigned.score >= 7
                            ? .high
                            : assigned.score >= 5 ? .medium : .low
            return HistoricalTransactionMatch(
                legacyTransactionId: legacyID,
                plaidTransactionId: transaction.id,
                confidence: confidence,
                score: assigned.score,
                isAutomatic:
                    equivalentOutcome
                    || (uniqueEnough && confidence >= .medium)
            )
        }
    }

    /// Institutions and YNAB importers do not consistently agree on whether
    /// the transaction date is the authorization date or the posted date.
    /// Treat either Plaid source date as valid and use the closer one.
    private func plausibleDayDistance(
        legacyDate: Date,
        plaidTransaction: FinancialTransactionSummary,
        calendar: Calendar
    ) -> Int {
        let postedDistance = absoluteDayDistance(
            legacyDate,
            plaidTransaction.postedDate,
            calendar: calendar
        )
        guard let authorizedDate = plaidTransaction.authorizedDate else {
            return postedDistance
        }
        return min(
            postedDistance,
            absoluteDayDistance(
                legacyDate,
                authorizedDate,
                calendar: calendar
            )
        )
    }

    /// Transaction IDs do not need to be uniquely paired when every plausible
    /// YNAB row yields the same user-visible classification. This is common
    /// for repeated same-price purchases on adjacent days. Stable source IDs
    /// remain part of the signature where they affect treatment or splits.
    private func classificationSignature(
        _ transaction: TransactionSummary
    ) -> String {
        let payee = FinancialTransactionSummary.normalizedDescription(
            transaction.payeeName ?? ""
        )
        let category = transaction.categoryId
            ?? FinancialTransactionSummary.normalizedDescription(
                transaction.categoryName ?? ""
            )
        let transfer = transaction.transferAccountId ?? ""
        let splits = transaction.subtransactions
            .filter { !$0.deleted }
            .map {
                [
                    String($0.amount.milliunits),
                    $0.categoryId
                        ?? FinancialTransactionSummary
                            .normalizedDescription(
                                $0.categoryName ?? ""
                            ),
                    $0.forecastTreatment?.rawValue ?? "",
                    $0.transferAccountId ?? "",
                    FinancialTransactionSummary.normalizedDescription(
                        $0.payeeName ?? ""
                    )
                ].joined(separator: "|")
            }
            .sorted()
            .joined(separator: ";")
        return [payee, category, transfer, splits]
            .joined(separator: "||")
    }

    private func absoluteDayDistance(
        _ lhs: Date,
        _ rhs: Date,
        calendar: Calendar
    ) -> Int {
        let start = calendar.startOfDay(for: min(lhs, rhs))
        let end = calendar.startOfDay(for: max(lhs, rhs))
        return calendar.dateComponents([.day], from: start, to: end).day ?? .max
    }

    private func similarityScore(_ lhs: String, _ rhs: String) -> Int {
        let a = FinancialTransactionSummary.normalizedDescription(lhs)
        let b = FinancialTransactionSummary.normalizedDescription(rhs)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 4 }
        if a.contains(b) || b.contains(a) { return 3 }
        let aTokens = Set(a.split(separator: " ").map(String.init))
        let bTokens = Set(b.split(separator: " ").map(String.init))
        let union = aTokens.union(bTokens)
        guard !union.isEmpty else { return 0 }
        let overlap = aTokens.intersection(bTokens).count
        let ratio = Double(overlap) / Double(union.count)
        if ratio >= 0.66 { return 3 }
        if ratio >= 0.33 { return 2 }
        if overlap > 0 { return 1 }
        return 0
    }
}

public struct TransactionClassifier: Sendable {
    public init() {}

    public func classify(
        _ transaction: FinancialTransactionSummary,
        rules: [MerchantClassificationRule],
        modelSuggestion: ModelClassificationSuggestion? = nil
    ) -> TransactionClassification {
        let rule = rules.first(where: {
            $0.confirmed && $0.fingerprint == transaction.merchantFingerprint
        })
        let defaultTreatment = forecastTreatment(for: transaction)
        let providerContradictsRule = rule.map {
            $0.categoryReusable
                && defaultTreatment != $0.treatment
        } ?? false

        if let rule, rule.categoryReusable, !providerContradictsRule {
            return TransactionClassification(
                displayName: rule.preferredName,
                categoryName: rule.categoryName,
                treatment: rule.treatment,
                confidence: .high,
                provenance: .confirmedRule,
                requiresReview: false
            )
        }

        let preferredName = rule?.preferredName

        if let modelSuggestion {
            return TransactionClassification(
                displayName: preferredName ?? modelSuggestion.displayName,
                treatment: defaultTreatment,
                confidence: modelSuggestion.confidence,
                provenance: modelSuggestion.provenance,
                requiresReview: true
            )
        }

        return TransactionClassification(
            displayName: preferredName ?? transaction.fallbackDisplayName,
            treatment: defaultTreatment,
            confidence: .low,
            provenance: .plaidEnrichment,
            requiresReview: true
        )
    }

    public func forecastTreatment(
        for transaction: FinancialTransactionSummary
    ) -> ForecastTreatment {
        let primary = transaction.providerCategoryPrimary?.uppercased() ?? ""
        let detailed = transaction.providerCategoryDetailed?.uppercased() ?? ""
        let code = transaction.transactionCode?.uppercased() ?? ""
        if detailed.contains("CARD_PAYMENT")
            || detailed.contains("CREDIT_CARD_PAYMENT") {
            return .cardPayment
        }
        if primary.contains("TRANSFER")
            || detailed.contains("TRANSFER")
            || code.contains("TRANSFER") {
            return .internalTransfer
        }
        if transaction.amount.isNegative {
            return .ordinarySpending
        }
        return primary.contains("INCOME") ? .income : .refund
    }
}
