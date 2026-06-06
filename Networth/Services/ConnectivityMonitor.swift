import Foundation
import Network
import Observation

@Observable
public final class ConnectivityMonitor: @unchecked Sendable {
    public private(set) var isOnline: Bool = true
    public private(set) var isExpensive: Bool = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.bluelava.me.networth.connectivity")

    public init() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.isOnline = path.status == .satisfied
                self?.isExpensive = path.isExpensive
            }
        }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }
}
