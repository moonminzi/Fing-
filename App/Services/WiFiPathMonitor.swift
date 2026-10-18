import Network

/// Wi-Fi 경로를 지켜보다가 연결·끊김·공유기 바뀜이 있을 때마다 알려 준다.
@MainActor
final class WiFiPathMonitor {
    struct Status: Equatable, Sendable {
        var isConnected: Bool
        /// Wi-Fi 인터페이스의 BSD 이름. 대개 en0이지만 아닌 기기도 있다(TN3179)
        var interfaceName: String?
    }

    private let monitor = NWPathMonitor(requiredInterfaceType: .wifi)

    func start(onChange: @escaping @MainActor @Sendable (Status) -> Void) {
        monitor.pathUpdateHandler = { @Sendable path in
            let status = Status(
                isConnected: path.status == .satisfied,
                interfaceName: path.availableInterfaces.first(where: { $0.type == .wifi })?.name
            )
            Task { @MainActor in onChange(status) }
        }
        monitor.start(queue: .main)
    }

    func stop() {
        monitor.cancel()
    }
}
