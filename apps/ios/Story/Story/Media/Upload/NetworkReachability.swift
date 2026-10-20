import Foundation
import Network

// R4-A.1 — minimal network-path monitor for the Wi-Fi-only upload gate. Reports whether the current path is
// usable and whether it is "expensive" (cellular/hotspot) so the upload queue can hold uploads until Wi-Fi
// when the account's Auto Backup is Wi-Fi-only. Observed, not blocking: callers read the latest snapshot.
@MainActor
final class NetworkReachability {
    static let shared = NetworkReachability()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "yotale.netpath")

    private(set) var isSatisfied = false      // a usable network path exists
    private(set) var isExpensive = true       // cellular / personal hotspot (conservative default until known)
    private(set) var isConstrained = false    // Low Data Mode

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            let expensive = path.isExpensive
            let constrained = path.isConstrained
            Task { @MainActor in
                self?.isSatisfied = satisfied
                self?.isExpensive = expensive
                self?.isConstrained = constrained
            }
        }
        monitor.start(queue: queue)
    }

    /// Is an upload allowed on the CURRENT path for this account's cellular preference?
    /// Wi-Fi-only (allowCellular == false): requires a satisfied, non-expensive, non-constrained path.
    /// Cellular allowed: any satisfied path.
    func uploadAllowed(allowCellular: Bool) -> Bool {
        guard isSatisfied else { return false }
        if allowCellular { return true }
        return !isExpensive && !isConstrained
    }
}
