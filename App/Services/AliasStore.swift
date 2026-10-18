import Foundation
import NagoNetCore

/// 기기 별명을 UserDefaults에 둔다. 열쇠는 `DeviceIdentity.keys`(Bonjour 이름 → 호스트 이름 → 네트워크별 IP).
struct AliasStore: AliasStoring {
    private static let key = "nagonet.aliases"

    func alias(forKeys keys: [String]) -> String? {
        let all = load()
        return keys.lazy.compactMap { all[$0] }.first
    }

    func setAlias(_ alias: String?, forKeys keys: [String]) {
        var all = load()
        keys.forEach { all[$0] = nil }
        if let alias, let first = keys.first {
            all[first] = alias
        }
        UserDefaults.standard.set(all, forKey: Self.key)
    }

    private func load() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: Self.key) as? [String: String] ?? [:]
    }
}
