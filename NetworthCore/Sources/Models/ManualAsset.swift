import Foundation
import Money

public enum ManualAssetKind: String, Sendable, Hashable, Codable, CaseIterable {
    case realEstate
    case vehicle
    case brokerage
    case retirement
    case crypto
    case collectible
    case other

    public var displayName: String {
        switch self {
        case .realEstate:  return "Real Estate"
        case .vehicle:     return "Vehicle"
        case .brokerage:   return "Brokerage"
        case .retirement:  return "Retirement"
        case .crypto:      return "Crypto"
        case .collectible: return "Collectible"
        case .other:       return "Other"
        }
    }
}

public struct ManualAssetValueEntry: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    public let recordedAt: Date
    public let value: Money
    public let note: String?

    public init(id: UUID = UUID(), recordedAt: Date, value: Money, note: String? = nil) {
        self.id = id
        self.recordedAt = recordedAt
        self.value = value
        self.note = note
    }
}

public struct ManualAssetSnapshot: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    public let name: String
    public let kind: ManualAssetKind
    public let currentValue: Money
    public let lastUpdatedAt: Date
    public let history: [ManualAssetValueEntry]

    public init(
        id: UUID,
        name: String,
        kind: ManualAssetKind,
        currentValue: Money,
        lastUpdatedAt: Date,
        history: [ManualAssetValueEntry] = []
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.currentValue = currentValue
        self.lastUpdatedAt = lastUpdatedAt
        self.history = history
    }

    /// True when the most-recent edit was >30 days before `referenceDate`.
    public func needsUpdate(referenceDate: Date) -> Bool {
        let interval = referenceDate.timeIntervalSince(lastUpdatedAt)
        return interval > 30 * 24 * 60 * 60
    }
}
