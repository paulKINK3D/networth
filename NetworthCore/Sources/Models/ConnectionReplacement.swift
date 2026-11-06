import Foundation

/// Suggestions only: institution names and masks are not proof of identity.
public enum ConnectionReplacementMatching {
    public struct Account: Equatable, Sendable {
        public let id: String
        public let connectionID: String
        public let institution: String
        public let mask: String?
        public let type: FinancialAccountType
        public let currency: String?

        public init(id: String, connectionID: String, institution: String,
                    mask: String?, type: FinancialAccountType, currency: String?) {
            self.id = id
            self.connectionID = connectionID
            self.institution = institution
            self.mask = mask
            self.type = type
            self.currency = currency
        }
    }

    public static func candidates(for account: Account, among accounts: [Account]) -> [Account] {
        let institution = normalized(account.institution)
        guard !institution.isEmpty, let mask = account.mask?.trimmingCharacters(in: .whitespacesAndNewlines),
              !mask.isEmpty else { return [] }
        return accounts.filter {
            $0.id != account.id && $0.connectionID != account.connectionID
                && normalized($0.institution) == institution
                && $0.mask?.trimmingCharacters(in: .whitespacesAndNewlines) == mask
                && $0.type == account.type
                && $0.currency == account.currency
        }.sorted { $0.id < $1.id }
    }

    public struct Transaction: Equatable, Sendable {
        public let id: String
        /// Provider civil date (yyyy-MM-dd), not a timezone-dependent instant.
        public let day: String
        public let amount: Int64
        public let description: String

        public init(id: String, day: String, amount: Int64, description: String) {
            self.id = id
            self.day = day
            self.amount = amount
            self.description = description
        }
    }

    public struct Match: Equatable, Sendable {
        public let existingID: String
        public let incomingID: String
    }

    public struct Ambiguity: Equatable, Sendable {
        public let existingIDs: [String]
        public let incomingIDs: [String]
    }

    public struct Plan: Equatable, Sendable {
        public let matches: [Match]
        public let ambiguities: [Ambiguity]
        public let retainedHistoryIDs: [String]
        public let newTransactionIDs: [String]
    }

    private struct Key: Hashable {
        let day: String
        let amount: Int64
        let description: String
    }

    /// Never pairs identical purchases by arbitrary ordering. A caller must
    /// obtain an explicit resolution for every ambiguous group before applying.
    public static func plan(existing: [Transaction], incoming: [Transaction]) -> Plan {
        func key(_ value: Transaction) -> Key {
            Key(day: value.day, amount: value.amount, description: normalized(value.description))
        }
        let old = Dictionary(grouping: existing, by: key)
        let new = Dictionary(grouping: incoming, by: key)
        var matches: [Match] = []
        var ambiguities: [Ambiguity] = []
        var retained: [String] = []
        var added: [String] = []
        for (key, rows) in old {
            guard !key.day.isEmpty, !key.description.isEmpty else {
                retained += rows.map(\.id)
                continue
            }
            guard let replacements = new[key] else {
                retained += rows.map(\.id)
                continue
            }
            if rows.count == 1, replacements.count == 1 {
                matches.append(Match(existingID: rows[0].id, incomingID: replacements[0].id))
            } else {
                ambiguities.append(Ambiguity(existingIDs: rows.map(\.id).sorted(),
                                             incomingIDs: replacements.map(\.id).sorted()))
            }
        }
        for (key, rows) in new where old[key] == nil || key.day.isEmpty || key.description.isEmpty {
            added += rows.map(\.id)
        }
        return Plan(matches: matches.sorted { $0.existingID < $1.existingID },
                    ambiguities: ambiguities.sorted { $0.existingIDs[0] < $1.existingIDs[0] },
                    retainedHistoryIDs: retained.sorted(), newTransactionIDs: added.sorted())
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

public extension FinancialTransactionSummary {
    func replacingIdentity(id: String, externalID: String, accountID: String) -> Self {
        Self(id: id, externalId: externalID, source: source, accountId: accountID,
             postedDate: postedDate, authorizedDate: authorizedDate, amount: amount,
             pending: pending, pendingTransactionId: pendingTransactionId,
             rawDescription: rawDescription, originalDescription: originalDescription,
             providerMerchantName: providerMerchantName, merchantEntityId: merchantEntityId,
             counterpartyName: counterpartyName, counterpartyType: counterpartyType,
             counterpartyEntityId: counterpartyEntityId, counterpartyConfidence: counterpartyConfidence,
             paymentChannel: paymentChannel, providerCategoryPrimary: providerCategoryPrimary,
             providerCategoryDetailed: providerCategoryDetailed,
             providerCategoryConfidence: providerCategoryConfidence, transactionCode: transactionCode)
    }
}
