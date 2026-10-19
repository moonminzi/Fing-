import Foundation
import NagoNetCore

/// 설정 화면의 값(UserDefaults). 화면은 @AppStorage로 같은 열쇠를 쓴다.
enum AppSettings {
    static let snmpEnabledKey = "nagonet.snmp.enabled"
    static let snmpCommunityKey = "nagonet.snmp.community"
    static let backgroundCheckKey = "nagonet.background.enabled"
    static let dhcpSniffKey = "nagonet.dhcp.sniff"

    /// 공유기·AP에 SNMP로 ARP 표를 물을지(기본 켬)
    static var snmpEnabled: Bool {
        UserDefaults.standard.object(forKey: snmpEnabledKey) as? Bool ?? true
    }

    /// SNMP 커뮤니티 문자열(기본 "public")
    static var snmpCommunity: String {
        let value = UserDefaults.standard.string(forKey: snmpCommunityKey)?.trimmingCharacters(in: .whitespaces) ?? ""
        return value.isEmpty ? "public" : value
    }

    /// DHCP 요청을 엿들어 MAC을 잡을지(실험, 기본 켬). 기기가 Wi-Fi에 붙거나 갱신하는 순간에만 잡히고,
    /// iOS가 그 브로드캐스트를 앱에 넘겨주는지는 기기마다 다르다.
    static var dhcpSniffEnabled: Bool {
        UserDefaults.standard.object(forKey: dhcpSniffKey) as? Bool ?? true
    }

    /// 앱이 꺼져 있을 때 가끔 새 기기를 확인해 알릴지(기본 끔)
    static var backgroundCheckEnabled: Bool {
        UserDefaults.standard.bool(forKey: backgroundCheckKey)
    }
}

/// MAC 앞자리 → 제조사 표. 앱 묶음의 oui.txt(1MB)를 처음 쓸 때 한 번 읽는다.
enum VendorLookup {
    static let database: OUIDatabase = {
        guard let url = Bundle.main.url(forResource: "oui", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return .empty }
        return OUIDatabase(text: text)
    }()

    static func vendor(for mac: MACAddress) -> String? {
        database.vendor(for: mac)
    }
}
