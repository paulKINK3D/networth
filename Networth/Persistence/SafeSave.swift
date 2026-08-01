import Foundation
import SwiftData
import os

extension Notification.Name {
    public static let networthPersistenceFailure = Notification.Name("NetworthPersistenceFailure")
    public static let networthModelContextSaved = Notification.Name(
        "NetworthModelContextSaved"
    )
}

public struct PersistenceFailure: Sendable, Equatable {
    public let source: String
    public let message: String
    public init(source: String, message: String) { self.source = source; self.message = message }
}

extension ModelContext {
    /// Drop-in replacement for `try? save()` that posts a notification on failure
    /// so a global handler can surface an alert instead of silently swallowing.
    @discardableResult
    public func safeSave(
        source: String,
        notifyDataSync: Bool = true
    ) -> Bool {
        do {
            try save()
            if notifyDataSync {
                NotificationCenter.default.post(
                    name: .networthModelContextSaved,
                    object: source
                )
            }
            return true
        } catch {
            let logger = Logger(subsystem: "com.bluelava.me.networth", category: "persistence")
            logger.error("safeSave[\(source, privacy: .public)] failed: \(error.localizedDescription, privacy: .public)")
            NotificationCenter.default.post(
                name: .networthPersistenceFailure,
                object: nil,
                userInfo: ["payload": PersistenceFailure(source: source, message: error.localizedDescription)]
            )
            return false
        }
    }
}
