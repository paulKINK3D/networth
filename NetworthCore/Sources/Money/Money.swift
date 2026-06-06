import Foundation

/// A monetary amount expressed in YNAB-style milliunits (1/1000 of a major unit).
/// Use this everywhere we move money around the app — never raw integers, never `Double`.
public struct Money: Sendable, Hashable, Codable {
    public let milliunits: Int64

    public init(milliunits: Int64) {
        self.milliunits = milliunits
    }

    public static let zero = Money(milliunits: 0)

    public static func dollars(_ value: Decimal) -> Money {
        let scaled = value * 1000
        var rounded = Decimal()
        var source = scaled
        NSDecimalRound(&rounded, &source, 0, .plain)
        let asNumber = NSDecimalNumber(decimal: rounded).int64Value
        return Money(milliunits: asNumber)
    }

    /// Convenience for tests that want an integer dollar amount. Integer
    /// literals are also accepted by `dollars(_:Decimal)`, so use this form
    /// only when you have an `Int` variable in hand.
    public static func dollars(integer value: Int) -> Money {
        Money(milliunits: Int64(value) * 1000)
    }

    public var isNegative: Bool { milliunits < 0 }
    public var isZero: Bool { milliunits == 0 }

    public var absolute: Money { Money(milliunits: abs(milliunits)) }

    /// Major-unit Decimal representation (e.g. milliunits 12345 → 12.345).
    public var decimalValue: Decimal {
        Decimal(milliunits) / 1000
    }

    /// Major-unit Double — convenient for charts. Do NOT use for math.
    public var doubleValue: Double {
        Double(milliunits) / 1000.0
    }
}

// MARK: - Arithmetic

extension Money {
    public static func + (lhs: Money, rhs: Money) -> Money {
        Money(milliunits: lhs.milliunits + rhs.milliunits)
    }

    public static func - (lhs: Money, rhs: Money) -> Money {
        Money(milliunits: lhs.milliunits - rhs.milliunits)
    }

    public static prefix func - (m: Money) -> Money {
        Money(milliunits: -m.milliunits)
    }

    public static func += (lhs: inout Money, rhs: Money) {
        lhs = lhs + rhs
    }

    public static func -= (lhs: inout Money, rhs: Money) {
        lhs = lhs - rhs
    }
}

extension Money: Comparable {
    public static func < (lhs: Money, rhs: Money) -> Bool {
        lhs.milliunits < rhs.milliunits
    }
}

extension Sequence where Element == Money {
    public func sum() -> Money {
        Money(milliunits: reduce(Int64(0)) { $0 + $1.milliunits })
    }
}

// MARK: - Scaling

extension Money {
    /// Multiplies a money amount by a fractional rate (e.g. 0.02 for 2%) and
    /// rounds half-to-even to the nearest milliunit. Used by the CC minimum-payment calc.
    public func scaled(by rate: Decimal) -> Money {
        let raw = Decimal(milliunits) * rate
        var rounded = Decimal()
        var src = raw
        NSDecimalRound(&rounded, &src, 0, .bankers)
        return Money(milliunits: NSDecimalNumber(decimal: rounded).int64Value)
    }
}
