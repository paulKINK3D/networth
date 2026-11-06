import Testing
@testable import NetworthCore

@Suite("Connection replacement matching")
struct ConnectionReplacementTests {
    @Test func missingEvidenceAndDifferentSignedAmountsNeverAutoMatch() {
        typealias Transaction = ConnectionReplacementMatching.Transaction
        let existing = [
            Transaction(id: "empty", day: "2026-11-01", amount: -1000, description: " "),
            Transaction(id: "debit", day: "2026-11-01", amount: -2000, description: "Shop")
        ]
        let incoming = [
            Transaction(id: "new-empty", day: "2026-11-01", amount: -1000, description: ""),
            Transaction(id: "credit", day: "2026-11-01", amount: 2000, description: "Shop")
        ]
        let plan = ConnectionReplacementMatching.plan(existing: existing, incoming: incoming)
        #expect(plan.matches.isEmpty)
        #expect(plan.retainedHistoryIDs.count == 2)
        #expect(plan.newTransactionIDs.count == 2)
    }

    @Test func multipleAccountCandidatesAreReturnedWithoutChoosingOne() {
        typealias Account = ConnectionReplacementMatching.Account
        let incoming = Account(id: "new", connectionID: "new", institution: "Bank",
                               mask: "1234", type: .creditCard, currency: "USD")
        let old = ["a", "b"].map {
            Account(id: $0, connectionID: $0, institution: "Bank",
                    mask: "1234", type: .creditCard, currency: "USD")
        }
        #expect(ConnectionReplacementMatching.candidates(for: incoming, among: old).map(\.id) == ["a", "b"])
    }

    @Test func accountSuggestionsRequireInstitutionMaskTypeAndDifferentConnection() {
        typealias Account = ConnectionReplacementMatching.Account
        func account(_ id: String, connection: String = "old", institution: String = "Bank",
                     mask: String? = "1234", type: FinancialAccountType = .creditCard) -> Account {
            Account(id: id, connectionID: connection, institution: institution,
                    mask: mask, type: type, currency: "USD")
        }
        let incoming = account("incoming", connection: "new")
        let candidates = ConnectionReplacementMatching.candidates(for: incoming, among: [
            account("match"), account("same-connection", connection: "new"),
            account("other-bank", institution: "Other"), account("no-mask", mask: nil),
            account("other-type", type: .checking), account("other-mask", mask: "5678")
        ])
        #expect(candidates.map(\.id) == ["match"])
        #expect(ConnectionReplacementMatching.candidates(for: account("missing", mask: nil),
                                                         among: [incoming]).isEmpty)
    }

    @Test func preservesOlderHistoryAndDoesNotGuessIdenticalPurchaseMatches() {
        typealias Transaction = ConnectionReplacementMatching.Transaction
        func transaction(_ id: String, day: String = "2026-11-01", amount: Int64 = -1000) -> Transaction {
            Transaction(id: id, day: day, amount: amount, description: "Shop")
        }
        let old = [transaction("old-1"), transaction("old-2", amount: -2000),
                   transaction("old-3", amount: -2000), transaction("history", day: "2023-01-01")]
        let new = [transaction("new-1"), transaction("new-2", amount: -2000),
                   transaction("new-3", amount: -2000), transaction("new-only", amount: -3000)]
        let plan = ConnectionReplacementMatching.plan(existing: old, incoming: new)
        #expect(plan.matches.count == 1)
        #expect(plan.matches.first?.existingID == "old-1")
        #expect(plan.matches.first?.incomingID == "new-1")
        #expect(plan.ambiguities.count == 1)
        #expect(plan.ambiguities.first?.existingIDs == ["old-2", "old-3"])
        #expect(plan.retainedHistoryIDs == ["history"])
        #expect(plan.newTransactionIDs == ["new-only"])
        #expect(plan == ConnectionReplacementMatching.plan(existing: old.reversed(), incoming: new.reversed()))
    }
}
