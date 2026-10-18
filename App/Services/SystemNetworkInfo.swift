import NagoNetCore
import NetworkExtension

/// 이 기기에서 내 네트워크를 읽는다: 주소·대역·게이트웨이는 Core(getifaddrs·라우팅 테이블), 이름은 NEHotspotNetwork.
struct SystemNetworkInfo: NetworkInfoProviding {
    func currentNetwork(interfaceName: String) async throws -> NetworkSnapshot {
        var snapshot = try NetworkSnapshot.current(interfaceName: interfaceName)
        snapshot.ssid = await Self.currentSSID()
        return snapshot
    }

    /// 연결된 Wi-Fi 이름(SSID).
    ///
    /// Access Wi-Fi Information entitlement와 정확한 위치 권한이 둘 다 있어야 값이 나오고, 아니면 nil.
    /// 완료 핸들러가 어느 큐에서 불릴지 몰라서 격리되지 않은(nonisolated) 곳에서 감싼다.
    static func currentSSID() async -> String? {
        await withCheckedContinuation { continuation in
            NEHotspotNetwork.fetchCurrent { network in
                let ssid = network?.ssid
                continuation.resume(returning: ssid?.isEmpty == false ? ssid : nil)
            }
        }
    }
}
