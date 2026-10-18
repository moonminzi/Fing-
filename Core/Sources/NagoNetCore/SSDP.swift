import Foundation

/// UPnP 기기 설명(description.xml)에서 읽은 것.
public struct UPnPDevice: Hashable, Sendable {
    /// 사용자가 붙인 이름("[TV] Samsung 7 Series (55)", "거실 스피커")
    public var friendlyName: String?
    public var manufacturer: String?
    public var modelName: String?
    public var modelNumber: String?
    /// "urn:schemas-upnp-org:device:MediaRenderer:1"
    public var deviceType: String?
    /// SSDP 응답의 SERVER 머리("Linux/4.4 UPnP/1.0 Sonos/70.3")
    public var server: String?
    /// 기기 고유 ID("uuid:2f402f80-da50-11e1-9b23-001788102201", Sonos는 "uuid:RINCON_…"). 버전 1 UUID면 MAC이 들어 있다
    public var udn: String?
    /// 설명에 MAC을 적어 두는 기기의 `<macAddress>`
    public var macAddress: String?

    public init(friendlyName: String? = nil, manufacturer: String? = nil, modelName: String? = nil,
                modelNumber: String? = nil, deviceType: String? = nil, server: String? = nil,
                udn: String? = nil, macAddress: String? = nil) {
        self.friendlyName = friendlyName
        self.manufacturer = manufacturer
        self.modelName = modelName
        self.modelNumber = modelNumber
        self.deviceType = deviceType
        self.server = server
        self.udn = udn
        self.macAddress = macAddress
    }

    /// deviceType의 짧은 이름("MediaRenderer")
    public var shortType: String? {
        deviceType.flatMap { $0.split(separator: ":").dropLast().last.map(String.init) }
    }

    /// "Samsung UN55TU7000"
    public var model: String? {
        let parts = [manufacturer, modelName ?? modelNumber].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    public var hints: [String] {
        [friendlyName, manufacturer, modelName, modelNumber, server].compactMap { $0 }
    }
}

/// SSDP 유니캐스트 검색(UPnP 1.1).
///
/// 멀티캐스트(239.255.255.250)로 보내려면 Apple의 멀티캐스트 entitlement가 필요하지만,
/// 기기 주소의 1900 포트로 직접 보내는 검색은 보통 UDP라서 필요 없다. UPnP 1.1을 따르는 TV·공유기·NAS·
/// 스피커가 답하고, 답에 든 LOCATION(설명 XML 주소)에서 이름·제조사·모델을 읽는다.
public enum SSDP {
    public static let port: UInt16 = 1900

    public static func searchRequest(to host: IPv4) -> [UInt8] {
        Array("""
        M-SEARCH * HTTP/1.1\r
        HOST: \(host):1900\r
        MAN: "ssdp:discover"\r
        ST: upnp:rootdevice\r
        USER-AGENT: iOS/17 UPnP/1.1 NAGO-NET/1.0\r
        \r

        """.utf8)
    }

    /// 검색 답에서 설명 XML 주소와 SERVER 머리.
    public static func parseResponse(_ bytes: [UInt8]) -> (location: String, server: String?)? {
        let text = String(decoding: bytes.prefix(4096), as: UTF8.self)
        guard text.hasPrefix("HTTP/1.1 200") || text.hasPrefix("HTTP/1.0 200") else { return nil }
        var location: String?
        var server: String?
        for line in text.split(whereSeparator: \.isNewline).dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch name {
            case "location": location = value
            case "server": server = value
            default: break
            }
        }
        return location.map { ($0, server) }
    }

    /// 설명 XML 주소를 (포트, 경로, HTTPS인지)로. 그 기기 자신의 주소가 아니면 nil(엉뚱한 곳에 요청하지 않게).
    public static func descriptionTarget(_ location: String, expectedHost: IPv4) -> (port: UInt16, path: String, tls: Bool)? {
        guard let url = URL(string: location), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, IPv4(host) == expectedHost else { return nil }
        let tls = scheme == "https"
        let port = url.port.flatMap { UInt16(exactly: $0) } ?? (tls ? 443 : 80)
        var path = url.path.isEmpty ? "/" : url.path
        if let query = url.query { path += "?" + query }
        return (port, path, tls)
    }

    /// 설명 XML(HTTP 응답째)에서 첫 기기(root device)의 정보를 꺼낸다.
    public static func describe(_ response: [UInt8], server: String?) -> UPnPDevice? {
        let text = String(decoding: response.prefix(128 * 1024), as: UTF8.self)
        let xml = text.range(of: "<root", options: .caseInsensitive).map { String(text[$0.lowerBound...]) } ?? text
        let device = UPnPDevice(
            friendlyName: element("friendlyName", in: xml),
            manufacturer: element("manufacturer", in: xml),
            modelName: element("modelName", in: xml),
            modelNumber: element("modelNumber", in: xml),
            deviceType: element("deviceType", in: xml),
            server: server.flatMap(ServiceBanner.clean),
            udn: element("UDN", in: xml),
            macAddress: element("macAddress", in: xml)
        )
        return device.friendlyName == nil && device.manufacturer == nil && device.modelName == nil ? nil : device
    }

    /// `<name>값</name>` 하나(네임스페이스 접두사가 붙어도: `<dlna:name>`은 무시하고 정확히 그 이름만)
    static func element(_ name: String, in xml: String) -> String? {
        guard let open = xml.range(of: "<\(name)>", options: .caseInsensitive),
              let close = xml.range(of: "</\(name)>", options: .caseInsensitive, range: open.upperBound..<xml.endIndex)
        else { return nil }
        let raw = String(xml[open.upperBound..<close.lowerBound])
        let unwrapped = raw.replacingOccurrences(of: "<![CDATA[", with: "").replacingOccurrences(of: "]]>", with: "")
        return ServiceBanner.clean(ServiceBanner.decodeEntities(unwrapped))
    }
}

/// HTTP GET 한 번(UPnP 설명 XML 읽기용). 앱은 NWConnection으로, 시험은 가짜로.
public protocol HTTPFetching: Sendable {
    /// 응답 전체(머리 + 몸). 실패하면 nil
    func get(host: IPv4, port: UInt16, path: String, tls: Bool) async -> [UInt8]?
}
