import Foundation

/// IPv6 주소(16바이트). mDNS AAAA 답에서 얻는다.
public struct IPv6Address: Hashable, Sendable, CustomStringConvertible {
    public let bytes: [UInt8]

    public init?(_ bytes: [UInt8]) {
        guard bytes.count == 16 else { return nil }
        self.bytes = bytes
    }

    /// fe80::/10
    public var isLinkLocal: Bool {
        bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80
    }

    /// 인터페이스 ID가 EUI-64(MAC 가운데에 ff:fe를 끼우고 U/L 비트를 뒤집은 것)면 그 MAC.
    /// 프린터·TV·공유기·IoT(리눅스·임베디드)가 흔히 이렇게 주소를 만든다. 애플·윈도우·안드로이드는 무작위 ID라 nil.
    public var embeddedMAC: MACAddress? {
        guard bytes[11] == 0xFF, bytes[12] == 0xFE else { return nil }
        return MACAddress([bytes[8] ^ 0x02, bytes[9], bytes[10], bytes[13], bytes[14], bytes[15]])
    }

    /// RFC 5952 꼴("fe80::211:32ff:fe12:3456"): 가장 긴 0 묶음(2개 이상)을 "::"로
    public var description: String {
        let groups = stride(from: 0, to: 16, by: 2).map { UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1]) }
        var best: Range<Int>?
        var start: Int?
        for index in 0...groups.count {
            if index < groups.count, groups[index] == 0 {
                if start == nil { start = index }
                continue
            }
            if let run = start, index - run >= 2, index - run > best?.count ?? 0 {
                best = run..<index
            }
            start = nil
        }
        let hex = groups.map { String($0, radix: 16) }
        guard let best else { return hex.joined(separator: ":") }
        return hex[..<best.lowerBound].joined(separator: ":") + "::" + hex[best.upperBound...].joined(separator: ":")
    }
}

/// 기기가 같은 Wi-Fi에 스스로 공개해 둔 MAC 단서를 읽는다.
///
/// iOS는 ARP 캐시의 MAC을 지워서 주지만(02:00:00:00:00:00), 많은 기기가 자기 MAC을 광고·ID·주소에 그대로 담아 둔다.
/// 여기 있는 것은 이미 받은 답(Bonjour·UPnP·mDNS·HTTP)을 푸는 일만 하고 따로 묻지 않는다(묻는 것은 `MACProber`).
public enum MACClues {
    // MARK: 기기 ID

    /// 버전 1 UUID의 노드(끝 12자리)는 UUID를 만든 기기의 MAC이다(RFC 4122 §4.1.6). UPnP 기기·프린터가 흔히 쓴다.
    /// "uuid:" 앞머리와 "::upnp:rootdevice" 꼬리는 무시한다. Sonos는 "RINCON_<MAC 12자리>01400".
    /// 버전 1이 아니거나, 노드가 무작위(멀티캐스트 비트)면 nil.
    public static func mac(fromUUID raw: some StringProtocol) -> MACAddress? {
        var text = Substring(raw).trimmingCharacters(in: .whitespaces)
        if text.lowercased().hasPrefix("uuid:") { text = String(text.dropFirst(5)) }
        if text.uppercased().hasPrefix("RINCON_") {
            return MACAddress(text.dropFirst(7).prefix(12))
        }
        let parts = text.prefix(36).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.map(\.count) == [8, 4, 4, 4, 12], parts.allSatisfy({ $0.allSatisfy(\.isHexDigit) }),
              parts[2].first == "1",                                   // 버전 1(시간 + MAC)
              let variant = parts[3].first, "89abAB".contains(variant),   // RFC 4122 변형
              let mac = MACAddress(parts[4]), mac.bytes[0] & 0x01 == 0     // 무작위 노드는 멀티캐스트 비트를 켠다
        else { return nil }
        return mac
    }

    // MARK: Bonjour

    /// Bonjour 서비스 하나에 든 MAC.
    ///
    /// - `_adisk._tcp`(Time Machine 디스크: NAS·AirPort·맥): TXT `sys=waMa=00:11:32:…,adVF=0x100`
    /// - `_workstation._tcp`(리눅스 avahi·시놀로지): 인스턴스 이름 "diskstation [00:11:32:aa:bb:cc]"
    /// - `_apple-mobdev2._tcp`(아이폰·아이패드 Wi-Fi 동기화): 인스턴스 이름 "aa:bb:cc:dd:ee:ff@fe80::…"
    /// - `_esphomelib._tcp`(ESPHome 기기): TXT `mac=AABBCCDDEEFF`
    /// - `_hue._tcp`(Hue 브리지): TXT `bridgeid=001788FFFE123456`(MAC 가운데에 FFFE)
    public static func mac(in service: BonjourService) -> MACAddress? {
        switch service.type {
        case "_adisk._tcp":
            for value in service.txt.values {
                for part in value.split(separator: ",") where part.lowercased().hasPrefix("wama=") {
                    if let mac = MACAddress(part.dropFirst(5)) { return mac }
                }
            }
            return nil
        case "_workstation._tcp":
            guard let open = service.name.lastIndex(of: "["), let close = service.name.lastIndex(of: "]"),
                  open < close else { return nil }
            return MACAddress(service.name[service.name.index(after: open)..<close])
        case "_apple-mobdev2._tcp":
            guard let at = service.name.firstIndex(of: "@") else { return nil }
            return MACAddress(service.name[..<at])
        case "_esphomelib._tcp":
            return service.txt["mac"].flatMap { MACAddress($0) }
        case "_hue._tcp":
            return service.txt["bridgeid"].flatMap(macFromBridgeID)
        default:
            return nil
        }
    }

    /// Hue 브리지 ID "001788FFFE123456" → 00:17:88:12:34:56
    static func macFromBridgeID(_ id: String) -> MACAddress? {
        let hex = Array(id.uppercased())
        guard hex.count == 16, String(hex[6..<10]) == "FFFE" else { return nil }
        return MACAddress(String(hex[0..<6] + hex[10..<16]))
    }

    // MARK: 기기 정보 API(HTTP 응답째)

    /// Roku `GET :8060/query/device-info`: 지금 쓰는 쪽(`network-type`)의 `wifi-mac`·`ethernet-mac`
    public static func rokuMAC(_ response: [UInt8]) -> MACAddress? {
        guard let body = body(of: response) else { return nil }
        let xml = String(decoding: body, as: UTF8.self)
        let wifi = SSDP.element("wifi-mac", in: xml).flatMap { MACAddress($0) }
        let ethernet = SSDP.element("ethernet-mac", in: xml).flatMap { MACAddress($0) }
        return SSDP.element("network-type", in: xml)?.lowercased() == "ethernet" ? ethernet ?? wifi : wifi ?? ethernet
    }

    /// 삼성 TV(2016년 이후) `GET :8001/api/v2/`: `{"device": {"wifiMac": "…"}}`
    public static func samsungTVMAC(_ response: [UInt8]) -> MACAddress? {
        guard let device = json(response)?["device"] as? [String: Any] else { return nil }
        return (device["wifiMac"] as? String).flatMap { MACAddress($0) }
    }

    /// Hue 브리지 `GET /api/config`(인증 없이 기본 설정): `mac`, `bridgeid`가 둘 다 있어야 Hue로 본다
    public static func hueMAC(_ response: [UInt8]) -> MACAddress? {
        guard let config = json(response), config["bridgeid"] is String else { return nil }
        return (config["mac"] as? String).flatMap { MACAddress($0) }
    }

    /// Shelly `GET /shelly`: `mac`(1세대는 `type`, 2세대는 `gen`·`id`가 같이 있다)
    public static func shellyMAC(_ response: [UInt8]) -> MACAddress? {
        guard let info = json(response), info["type"] != nil || info["gen"] != nil else { return nil }
        return (info["mac"] as? String).flatMap { MACAddress($0) }
    }

    /// 200 응답의 몸
    static func body(of response: [UInt8]) -> ArraySlice<UInt8>? {
        let head = String(decoding: response.prefix(16), as: UTF8.self)
        guard head.hasPrefix("HTTP/1.1 200") || head.hasPrefix("HTTP/1.0 200") else { return nil }
        let separator: [UInt8] = [13, 10, 13, 10]
        guard let end = response.indices.dropLast(3).first(where: { response[$0..<($0 + 4)].elementsEqual(separator) })
        else { return nil }
        return response[(end + 4)...]
    }

    private static func json(_ response: [UInt8]) -> [String: Any]? {
        guard let body = body(of: response) else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(body))) as? [String: Any]
    }
}

extension Device {
    /// 이미 받은 답(Bonjour·UPnP·IPv6)에서 MAC 단서를 다시 읽어 `reportedMACs`를 고친다. 바뀌었으면 true.
    ///
    /// 기기 ID(UUID)와 IPv6는 우연히 MAC 꼴이 될 수 있어서 `isRegistered`(IEEE에 등록된 제조사 번호인지)로 거른다.
    /// 기기에 직접 물어 얻은 것(`deviceSNMP`·`deviceAPI`)은 그대로 둔다.
    @discardableResult
    public mutating func refreshReportedMACs(isRegistered: (MACAddress) -> Bool) -> Bool {
        var found = reportedMACs.filter { $0.key == .deviceSNMP || $0.key == .deviceAPI }
        found[.bonjour] = services.lazy.compactMap(MACClues.mac(in:)).first

        let printerIDs = services.filter { ["_ipp._tcp", "_printer._tcp"].contains($0.type) }.compactMap { $0.txt["uuid"] }
        let upnpIDs = [upnp?.macAddress, upnp?.udn].compactMap { $0 }
        found[.deviceID] = upnp?.macAddress.flatMap { MACAddress($0) }
            ?? (upnpIDs + printerIDs).lazy.compactMap { MACClues.mac(fromUUID: $0) }.first(where: isRegistered)
        found[.ipv6] = ipv6Addresses.lazy.compactMap(\.embeddedMAC).first(where: isRegistered)

        guard found != reportedMACs else { return false }
        reportedMACs = found
        return true
    }
}
