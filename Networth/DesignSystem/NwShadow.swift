import SwiftUI

public enum NwShadow {
    public struct Spec: Sendable {
        public let color: Color
        public let radius: CGFloat
        public let x: CGFloat
        public let y: CGFloat
    }

    public static let card    = Spec(color: .black.opacity(0.06), radius: 8,  x: 0, y: 4)
    public static let elevated = Spec(color: .black.opacity(0.12), radius: 16, x: 0, y: 8)
    public static let none    = Spec(color: .clear, radius: 0, x: 0, y: 0)
}

extension View {
    public func nwShadow(_ spec: NwShadow.Spec) -> some View {
        self.shadow(color: spec.color, radius: spec.radius, x: spec.x, y: spec.y)
    }
}
