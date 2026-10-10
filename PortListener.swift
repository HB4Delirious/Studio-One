import Foundation
import Network

/// Opens a listener on the first port in a range that actually binds.
///
/// `NWListener` doesn't refuse a busy port when created: it starts, then
/// fails with "Address already in use". So each attempt is awaited until it
/// reports ready or failed before the next port is tried.
enum PortListener {

    /// `configure` sets the connection handler; it runs before the listener
    /// starts. Once ready, the listener's state handler is the caller's to set.
    static func open(ports: ClosedRange<UInt16>,
                     parameters makeParameters: (UInt16) -> NWParameters,
                     queue: DispatchQueue,
                     configure: (NWListener) -> Void) async -> (listener: NWListener, port: UInt16)? {
        for port in ports {
            let parameters = makeParameters(port)
            // Bound to one address, the port travels in the parameters;
            // otherwise it is given separately.
            let made = parameters.requiredLocalEndpoint != nil
                ? try? NWListener(using: parameters)
                : NWEndpoint.Port(rawValue: port).flatMap { try? NWListener(using: parameters, on: $0) }
            guard let listener = made else { continue }
            configure(listener)
            if await start(listener, on: queue) { return (listener, port) }
        }
        return nil
    }

    /// True once ready, false if it failed or was cancelled first.
    private static func start(_ listener: NWListener, on queue: DispatchQueue) async -> Bool {
        await withCheckedContinuation { continuation in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume(returning: true) }
                case .failed, .cancelled:
                    if once.claim() {
                        listener.cancel()
                        continuation.resume(returning: false)
                    }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    /// A continuation may be resumed exactly once; a listener can report
    /// ready and then fail.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }
}
