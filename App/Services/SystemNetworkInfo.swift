import NagoNetCore
import NetworkExtension

/// 이 기기에서 내 네트워크를 읽는다: 주소·대역·게이트웨이는 Core(getifaddrs·라우팅 테이블), 이름은 NEHotspotNetwork.
struct SystemNetworkInfo: NetworkInfoProviding {
    func currentNetwork(interfaceName: String) async throws -> NetworkSnapshot {
        var snapshot = try NetworkSnapshot.current(interfaceName: interfaceName)
        let wifi = await Self.currentWiFi()
        snapshot.ssid = wifi.ssid
        snapshot.bssid = wifi.bssid
        return snapshot
    }

    /// 연결된 Wi-Fi의 이름(SSID)과 접속 AP의 MAC(BSSID).
    ///
    /// Access Wi-Fi Information entitlement와 정확한 위치 권한이 둘 다 있어야 값이 나오고, 아니면 nil.
    /// BSSID는 iOS가 읽게 해 주는 남의 MAC — 접속한 AP의 하드웨어 주소다(무작위가 아니라 제조사가 나온다).
    /// 완료 핸들러가 어느 큐에서 불릴지 몰라서 격리되지 않은(nonisolated) 곳에서 감싼다.
    static func currentWiFi() async -> (ssid: String?, bssid: MACAddress?) {
        await withCheckedContinuation { (continuation: CheckedContinuation<(ssid: String?, bssid: MACAddress?), Never>) in
            NEHotspotNetwork.fetchCurrent { network in
                let ssid = network?.ssid
                let bssid = network?.bssid.flatMap { MACAddress($0) }
                continuation.resume(returning: (ssid?.isEmpty == false ? ssid : nil, bssid))
            }
        }
    }
}
