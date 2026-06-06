import SwiftUI

public enum NwTypography {
    public static let displayLarge = Font.system(size: 44, weight: .bold,    design: .rounded)
    public static let display      = Font.system(size: 34, weight: .bold,    design: .rounded)
    public static let title        = Font.system(size: 28, weight: .bold,    design: .rounded)
    public static let titleSmall   = Font.system(size: 22, weight: .semibold,design: .rounded)
    public static let headline     = Font.system(size: 17, weight: .semibold,design: .rounded)
    public static let body         = Font.system(size: 16, weight: .regular, design: .rounded)
    public static let bodyEmphasis = Font.system(size: 16, weight: .semibold,design: .rounded)
    public static let callout      = Font.system(size: 15, weight: .regular, design: .rounded)
    public static let footnote     = Font.system(size: 13, weight: .regular, design: .rounded)
    public static let footnoteEm   = Font.system(size: 13, weight: .semibold,design: .rounded)
    public static let caption      = Font.system(size: 11, weight: .regular, design: .rounded)
    public static let monoMetric   = Font.system(size: 28, weight: .bold,    design: .monospaced)
}
