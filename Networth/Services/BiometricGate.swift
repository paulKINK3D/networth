import Foundation
import LocalAuthentication

public protocol BiometricGate: Sendable {
    var isAvailable: Bool { get }
    var displayName: String { get }
    func authenticate(reason: String) async throws -> Bool
}

public enum BiometricGateError: Error, Sendable {
    case userCanceled
    case notEnrolled
    case unknown(Error)
}

public struct LocalAuthBiometricGate: BiometricGate {
    public init() {}

    public var isAvailable: Bool {
        let ctx = LAContext()
        var err: NSError?
        return ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err)
    }

    public var displayName: String {
        let ctx = LAContext()
        var err: NSError?
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err)
        switch ctx.biometryType {
        case .faceID:   return "Face ID"
        case .touchID:  return "Touch ID"
        case .opticID:  return "Optic ID"
        case .none:     return "Passcode"
        @unknown default: return "Passcode"
        }
    }

    public func authenticate(reason: String) async throws -> Bool {
        let ctx = LAContext()
        ctx.localizedFallbackTitle = "Enter Passcode"
        do {
            return try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch let err as LAError {
            switch err.code {
            case .userCancel, .systemCancel, .appCancel:
                throw BiometricGateError.userCanceled
            case .biometryNotEnrolled, .passcodeNotSet:
                throw BiometricGateError.notEnrolled
            default:
                throw BiometricGateError.unknown(err)
            }
        }
    }
}

/// Scriptable fake for previews and tests.
public struct ScriptableBiometricGate: BiometricGate {
    public let isAvailable: Bool
    public let displayName: String
    public let outcome: Bool

    public init(isAvailable: Bool = true, displayName: String = "Face ID", outcome: Bool = true) {
        self.isAvailable = isAvailable
        self.displayName = displayName
        self.outcome = outcome
    }

    public func authenticate(reason: String) async throws -> Bool { outcome }
}
