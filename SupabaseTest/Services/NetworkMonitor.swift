import Foundation
import Network
import Combine

@MainActor
protocol NetworkMonitoring: AnyObject {
    var isConnected: Bool { get }
    func setConnectivityRestoredHandler(_ handler: @escaping @MainActor () async -> Void)
}

@MainActor
final class NetworkMonitor: ObservableObject {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "NetworkMonitor")

    @Published private(set) var isConnected = true
    @Published private(set) var connectionType: ConnectionType = .unknown

    enum ConnectionType {
        case wifi
        case cellular
        case wired
        case unknown
    }

    private var onConnectivityRestored: (@MainActor () async -> Void)?

    init() {
        startMonitoring()
    }

    deinit {
        monitor.cancel()
    }

    func setConnectivityRestoredHandler(_ handler: @escaping @MainActor () async -> Void) {
        self.onConnectivityRestored = handler
    }

    private func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self = self else { return }

                let wasConnected = self.isConnected
                self.isConnected = path.status == .satisfied

                self.connectionType = self.getConnectionType(path)

                print("[Network] Status: \(self.isConnected ? "Connected" : "Disconnected"), Type: \(self.connectionType)")

                // Trigger sync when coming back online
                if !wasConnected && self.isConnected {
                    print("[Network] Connectivity restored, triggering sync...")
                    await self.onConnectivityRestored?()
                }
            }
        }
        monitor.start(queue: queue)
    }

    private func getConnectionType(_ path: NWPath) -> ConnectionType {
        if path.usesInterfaceType(.wifi) {
            return .wifi
        } else if path.usesInterfaceType(.cellular) {
            return .cellular
        } else if path.usesInterfaceType(.wiredEthernet) {
            return .wired
        } else {
            return .unknown
        }
    }
}

extension NetworkMonitor: NetworkMonitoring {}
