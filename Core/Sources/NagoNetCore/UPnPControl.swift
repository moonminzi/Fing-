import Foundation

/// UPnP **SOAP 제어** — 인가받은 자기 네트워크·CTF 전용.
///
/// 발견한 기기(공유기 IGD / DLNA 렌더러)의 controlURL로 SOAP 액션을 보낸다. UPnP는 설계상 **인증이 없어서**
/// 같은 LAN의 클라이언트가 보낸 호출을 기기가 그대로 수행한다 — 그래서 실제로 먹히고(정찰·제어), 그래서 침습적이다.
/// ARP·NDP 스푸핑은 iOS 커널이 막지만(EPERM), 이건 평범한 유니캐스트 TCP/HTTP POST라 샌드박스 제약을 받지 않는다.
///
/// 여기 있는 것은 전부 **순수 바이트/문자열 조립·파싱**이라 플랫폼과 무관하게 `swift test`로 검증된다.
/// 실제 전송은 `HTTPFetching.post`가 맡는다(앱은 NWConnection, 시험은 가짜).
public enum UPnPControl {
    /// 공유기 IGD의 WAN 연결 서비스(기기마다 IP판/PPP판으로 갈린다 — 둘 다 시도한다)
    public static let wanIPConnection = "urn:schemas-upnp-org:service:WANIPConnection:1"
    public static let wanPPPConnection = "urn:schemas-upnp-org:service:WANPPPConnection:1"
    /// DLNA 미디어 렌더러(TV·스피커)의 재생 제어 서비스
    public static let avTransport = "urn:schemas-upnp-org:service:AVTransport:1"

    /// SOAP 1.1 엔벨로프. 돌려주는 `soapAction`은 `"<serviceType>#<action>"`(따옴표 포함, 헤더에 그대로).
    public static func envelope(serviceType: String, action: String, args: [(String, String)]) -> (soapAction: String, body: [UInt8]) {
        let inner = args.map { "<\($0.0)>\(xmlEscape($0.1))</\($0.0)>" }.joined()
        let xml = "<?xml version=\"1.0\"?>"
            + "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" "
            + "s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">"
            + "<s:Body><u:\(action) xmlns:u=\"\(serviceType)\">\(inner)</u:\(action)></s:Body>"
            + "</s:Envelope>"
        return ("\"\(serviceType)#\(action)\"", Array(xml.utf8))
    }

    // MARK: - 공유기(IGD)

    /// 공유기의 공인(WAN) IP를 묻는다(정찰). 응답의 NewExternalIPAddress.
    public static func getExternalIPAddress(serviceType: String = wanIPConnection) -> (soapAction: String, body: [UInt8]) {
        envelope(serviceType: serviceType, action: "GetExternalIPAddress", args: [])
    }

    /// 포워딩 표의 index번째 항목을 묻는다(정찰). index를 0부터 올리다 폴트(SpecifiedArrayIndexInvalid)가 나면 끝.
    public static func getGenericPortMappingEntry(index: Int, serviceType: String = wanIPConnection) -> (soapAction: String, body: [UInt8]) {
        envelope(serviceType: serviceType, action: "GetGenericPortMappingEntry", args: [("NewPortMappingIndex", String(index))])
    }

    /// 포워딩 규칙을 **만든다**(변경, 인가 전용). 공인 포트 → 내부 호스트:포트. 하드닝된 공유기는 내부 클라이언트를
    /// 호출자 자신으로만 제한하기도 한다. `leaseSeconds`가 지나면 저절로 사라진다(0이면 영구 — 꼭 롤백할 것).
    public static func addPortMapping(externalPort: UInt16, protocolTCP: Bool, internalPort: UInt16, internalClient: IPv4,
                                      description: String, leaseSeconds: Int,
                                      serviceType: String = wanIPConnection) -> (soapAction: String, body: [UInt8]) {
        envelope(serviceType: serviceType, action: "AddPortMapping", args: [
            ("NewRemoteHost", ""),
            ("NewExternalPort", String(externalPort)),
            ("NewProtocol", protocolTCP ? "TCP" : "UDP"),
            ("NewInternalPort", String(internalPort)),
            ("NewInternalClient", internalClient.description),
            ("NewEnabled", "1"),
            ("NewPortMappingDescription", description),
            ("NewLeaseDuration", String(leaseSeconds)),
        ])
    }

    /// 포워딩 규칙을 **지운다**(롤백). addPortMapping으로 연 것을 되돌릴 때.
    public static func deletePortMapping(externalPort: UInt16, protocolTCP: Bool,
                                         serviceType: String = wanIPConnection) -> (soapAction: String, body: [UInt8]) {
        envelope(serviceType: serviceType, action: "DeletePortMapping", args: [
            ("NewRemoteHost", ""),
            ("NewExternalPort", String(externalPort)),
            ("NewProtocol", protocolTCP ? "TCP" : "UDP"),
        ])
    }

    // MARK: - DLNA 렌더러(AVTransport)

    /// 렌더러에 **재생할 URL을 지정**한다(변경, 인가 전용). 뒤이어 `play`를 보내면 그 URL을 가져와 튼다(blind SSRF로도 쓰임).
    public static func setAVTransportURI(uri: String, metadata: String = "", instanceID: Int = 0) -> (soapAction: String, body: [UInt8]) {
        envelope(serviceType: avTransport, action: "SetAVTransportURI", args: [
            ("InstanceID", String(instanceID)),
            ("CurrentURI", uri),
            ("CurrentURIMetaData", metadata),
        ])
    }

    /// 지정한 URL을 재생시킨다(변경, 인가 전용).
    public static func play(speed: String = "1", instanceID: Int = 0) -> (soapAction: String, body: [UInt8]) {
        envelope(serviceType: avTransport, action: "Play", args: [
            ("InstanceID", String(instanceID)),
            ("Speed", speed),
        ])
    }

    // MARK: - 응답 읽기

    /// SOAP 응답 본문에서 쓸 만한 out-arg들을 꺼낸다(GetExternalIPAddress·GetGenericPortMappingEntry 등). `element` 재사용.
    public static func parseResponse(_ bytes: [UInt8]) -> [String: String] {
        let xml = bodyXML(bytes)
        var result: [String: String] = [:]
        for name in ["NewExternalIPAddress", "NewRemoteHost", "NewExternalPort", "NewProtocol",
                     "NewInternalPort", "NewInternalClient", "NewEnabled", "NewPortMappingDescription", "NewLeaseDuration"] {
            if let value = SSDP.element(name, in: xml) { result[name] = value }
        }
        return result
    }

    /// SOAP 폴트가 있으면 (UPnP errorCode, errorDescription). 성공 응답이면 nil.
    public static func fault(_ bytes: [UInt8]) -> (code: String, description: String)? {
        let xml = bodyXML(bytes)
        guard xml.range(of: "Fault", options: .caseInsensitive) != nil else { return nil }
        let code = SSDP.element("errorCode", in: xml) ?? "?"
        let description = SSDP.element("errorDescription", in: xml) ?? ""
        return (code, description)
    }

    /// HTTP 응답(머리 포함)에서 본문 XML만 떼어 낸다.
    static func bodyXML(_ bytes: [UInt8]) -> String {
        let text = String(decoding: bytes.prefix(128 * 1024), as: UTF8.self)
        if let separator = text.range(of: "\r\n\r\n") { return String(text[separator.upperBound...]) }
        if let separator = text.range(of: "\n\n") { return String(text[separator.upperBound...]) }
        return text
    }

    /// SOAP 인자 값에 든 특수문자를 XML로 피한다(& < > " ).
    static func xmlEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
