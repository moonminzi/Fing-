import Foundation
import NagoNetCore

/// 이름(mDNS·Bonjour)으로 잡은 MAC을 UserDefaults에 기억해 둔다.
///
/// DHCP 스니핑은 기회성이라(기기가 붙거나 갱신하는 순간만), 아이패드·아이폰은 한 스캔에서 잡혀도 다음엔 또 비기 쉽다.
/// Apple 기기는 mDNS 이름("…-iPad.local")이 안정적이라, 그 이름을 열쇠로 MAC을 기억해 두면 한 번만 잡혀도 계속 보여 줄 수 있다.
struct MACMemoryStore: MACMemoryStoring {
    private static let key = "nagonet.macMemory"

    func recall(forKeys keys: [String]) -> MACAddress? {
        let all = load()
        return keys.lazy.compactMap { all[$0] }.compactMap { MACAddress($0) }.first
    }

    func remember(_ mac: MACAddress, forKeys keys: [String]) {
        guard !keys.isEmpty else { return }
        var all = load()
        let value = mac.description
        var changed = false
        for key in keys where all[key] != value {
            all[key] = value
            changed = true
        }
        if changed {
            UserDefaults.standard.set(all, forKey: Self.key)
        }
    }

    private func load() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: Self.key) as? [String: String] ?? [:]
    }
}
