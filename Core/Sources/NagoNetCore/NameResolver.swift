import Foundation

/// 기기 하나에 대해 여러 곳에서 찾은 이름.
public struct DeviceNames: Hashable, Sendable {
    /// 공유기 DNS의 역방향 이름(PTR)
    public var dnsName: String?
    /// 기기가 직접 알려 준 mDNS 호스트 이름("Minjis-iPhone.local")
    public var mdnsName: String?
    /// 윈도우·삼바의 NetBIOS 컴퓨터 이름
    public var netbiosName: String?
    /// 기기가 직접 알려 준 Bonjour 서비스
    public var services: [BonjourService]
    /// 애플 기기의 `_device-info` 모델 식별자("iPad13,1")
    public var model: String?
    /// NetBIOS 답에 든 MAC(윈도우)
    public var netbiosMAC: MACAddress?
    /// SSDP 유니캐스트로 읽은 UPnP 기기 설명
    public var upnp: UPnPDevice?
    /// mDNS 호스트 이름의 IPv6 주소(AAAA)
    public var ipv6: [IPv6Address]

    public init(dnsName: String? = nil, mdnsName: String? = nil, netbiosName: String? = nil,
                services: [BonjourService] = [], model: String? = nil, netbiosMAC: MACAddress? = nil,
                upnp: UPnPDevice? = nil, ipv6: [IPv6Address] = []) {
        self.dnsName = dnsName
        self.mdnsName = mdnsName
        self.netbiosName = netbiosName
        self.services = services
        self.model = model
        self.netbiosMAC = netbiosMAC
        self.upnp = upnp
        self.ipv6 = ipv6
    }
}

/// IP 하나의 이름을 찾는다.
public protocol DeviceNaming: Sendable {
    func names(for address: IPv4) async -> DeviceNames
}

/// UDP 데이터그램 하나를 보내고 첫 답을 받는다. 앱은 NWConnection으로, 시험은 가짜로.
public protocol DatagramExchanging: Sendable {
    /// 답이 없거나(시간 초과) 거부되면 nil
    func exchange(_ payload: [UInt8], with host: IPv4, port: UInt16, timeout: Duration) async -> [UInt8]?
}

/// 역방향 DNS + 기기에 직접 묻는 질의 세 가지를 함께 돌린다.
///
/// - **mDNS 유니캐스트**(기기의 UDP 5353): 멀티캐스트를 막아 둔 Wi-Fi(회사·아파트·관리형 AP)에서도
///   애플 기기·리눅스(avahi)·프린터는 직접 온 질의에 답한다(RFC 6762 §5.5, 6.7). 호스트 이름(역방향 PTR)과
///   Bonjour 서비스 이름(서비스 종류별 PTR)을 묻는다. 멀티캐스트가 아니라서 별도 entitlement가 필요 없다.
/// - **NetBIOS 이름 상태**(UDP 137): 윈도우 PC·삼바 NAS의 컴퓨터 이름과 MAC.
/// - **SSDP 유니캐스트**(UDP 1900, `http`가 있을 때): UPnP 기기의 이름·제조사·모델(TV·공유기·NAS·스피커).
public struct NameResolver: DeviceNaming {
    private let dns: any HostNameResolving
    private let transport: any DatagramExchanging
    private let http: (any HTTPFetching)?
    private let timeout: Duration

    public init(dns: any HostNameResolving, transport: any DatagramExchanging, http: (any HTTPFetching)? = nil,
                timeout: Duration = .milliseconds(1500)) {
        self.dns = dns
        self.transport = transport
        self.http = http
        self.timeout = timeout
    }

    public func names(for address: IPv4) async -> DeviceNames {
        async let dnsName = dns.hostName(for: address)
        async let mdnsHost = mdnsHost(of: address)
        async let details = mdnsServiceDetails(of: address)
        async let netbios = netbiosStatus(of: address)
        async let upnp = upnpDevice(of: address)
        let (services, model) = await details
        let status = await netbios
        let host = await mdnsHost
        return await DeviceNames(dnsName: dnsName, mdnsName: host.name, netbiosName: status?.name,
                                 services: services, model: model, netbiosMAC: status?.mac, upnp: upnp, ipv6: host.ipv6)
    }

    /// SSDP 검색을 기기에 직접 보내고, 답의 LOCATION에서 설명 XML을 읽는다.
    private func upnpDevice(of address: IPv4) async -> UPnPDevice? {
        guard let http,
              let reply = await transport.exchange(SSDP.searchRequest(to: address), with: address, port: SSDP.port, timeout: timeout),
              let (location, server) = SSDP.parseResponse(reply),
              let target = SSDP.descriptionTarget(location, expectedHost: address),
              let body = await http.get(host: address, port: target.port, path: target.path, tls: target.tls)
        else { return nil }
        return SSDP.describe(body, server: server)
    }

    /// 서비스 이름을 묻고, 찾았으면 한 번 더 TXT(포트 정보가 빠진 서비스)와 `_device-info`(모델)를 묻는다.
    private func mdnsServiceDetails(of address: IPv4) async -> ([BonjourService], String?) {
        var services = await mdnsServices(of: address)
        guard !services.isEmpty else { return ([], nil) }

        let missingTXT = services.filter { $0.txt.isEmpty }.map { "\($0.name).\($0.type).local" }
        // 애플 기기는 기기 이름으로 `<이름>._device-info._tcp.local` TXT에 model을 둔다
        let deviceInfo = services.first { $0.type == "_companion-link._tcp" || $0.type == "_airplay._tcp" }
            .map { "\($0.name)._device-info._tcp.local" }
        let names = Array((missingTXT + [deviceInfo].compactMap { $0 }).prefix(10))
        let id = UInt16.random(in: 1...UInt16.max)
        let query = DNSMessage.query(id: id, questions: names.map { ($0, DNSMessage.RecordType.txt) })
        guard let reply = await transport.exchange(query, with: address, port: 5353, timeout: timeout) else {
            return (services, nil)
        }
        var texts: [String: [String: String]] = [:]
        for record in DNSMessage.records(in: reply, id: id) {
            if case .txt(let entries) = record.data { texts[record.name.lowercased()] = entries }
        }
        services = services.map { service in
            guard service.txt.isEmpty, let txt = texts["\(service.name).\(service.type).local".lowercased()] else { return service }
            return BonjourService(name: service.name, type: service.type, address: service.address, port: service.port, txt: txt)
        }
        let model = deviceInfo.flatMap { texts[$0.lowercased()]?["model"] }
        return (services, model)
    }

    /// 역방향 PTR로 호스트 이름을 묻고, 그 이름의 IPv6 주소(AAAA)도 받는다. 답에 딸려 오지 않았으면 한 번 더 묻는다.
    private func mdnsHost(of address: IPv4) async -> (name: String?, ipv6: [IPv6Address]) {
        let id = UInt16.random(in: 1...UInt16.max)
        let reverse = DNSMessage.reverseName(for: address)
        let query = DNSMessage.query(id: id, questions: [(reverse, DNSMessage.RecordType.ptr)])
        guard let reply = await transport.exchange(query, with: address, port: 5353, timeout: timeout) else { return (nil, []) }
        let records = DNSMessage.records(in: reply, id: id)
        guard let name = Self.hostName(in: records, reverseName: reverse) else { return (nil, []) }
        var ipv6 = Self.ipv6(in: records, host: name)
        if ipv6.isEmpty {
            let id = UInt16.random(in: 1...UInt16.max)
            let query = DNSMessage.query(id: id, questions: [(name, DNSMessage.RecordType.aaaa)])
            if let reply = await transport.exchange(query, with: address, port: 5353, timeout: timeout) {
                ipv6 = Self.ipv6(in: DNSMessage.records(in: reply, id: id), host: name)
            }
        }
        return (name, ipv6)
    }

    /// 호스트 이름의 AAAA 레코드들(링크 로컬 먼저)
    static func ipv6(in records: [DNSRecord], host: String) -> [IPv6Address] {
        var found: [IPv6Address] = []
        for record in records where record.name.caseInsensitiveCompare(host) == .orderedSame {
            if case .aaaa(let address) = record.data, !found.contains(address) { found.append(address) }
        }
        return found.filter(\.isLinkLocal) + found.filter { !$0.isLinkLocal }
    }

    private func mdnsServices(of address: IPv4) async -> [BonjourService] {
        let id = UInt16.random(in: 1...UInt16.max)
        let questions = BonjourCatalog.serviceTypes.map { ("\($0).local", DNSMessage.RecordType.ptr) }
        let query = DNSMessage.query(id: id, questions: questions)
        guard let reply = await transport.exchange(query, with: address, port: 5353, timeout: timeout) else { return [] }
        return Self.services(in: DNSMessage.records(in: reply, id: id), address: address)
    }

    private func netbiosStatus(of address: IPv4) async -> (name: String?, mac: MACAddress?)? {
        let id = UInt16.random(in: 1...UInt16.max)
        guard let reply = await transport.exchange(NetBIOS.nodeStatusRequest(id: id), with: address, port: 137, timeout: timeout)
        else { return nil }
        return NetBIOS.nodeStatus(in: reply)
    }

    /// 역방향 PTR 답에서 호스트 이름
    static func hostName(in records: [DNSRecord], reverseName: String) -> String? {
        for record in records where record.name.caseInsensitiveCompare(reverseName) == .orderedSame {
            if case .ptr(let target) = record.data, !target.isEmpty { return target }
        }
        return nil
    }

    /// 서비스 종류 PTR 답에서 인스턴스 이름을, 같은 답에 딸려 온 SRV·TXT에서 포트·TXT를 꺼낸다.
    static func services(in records: [DNSRecord], address: IPv4) -> [BonjourService] {
        var ports: [String: UInt16] = [:]
        var texts: [String: [String: String]] = [:]
        for record in records {
            switch record.data {
            case .srv(let port, _): ports[record.name.lowercased()] = port
            case .txt(let entries): texts[record.name.lowercased()] = entries
            default: break
            }
        }
        var found: [BonjourService] = []
        for record in records {
            guard case .ptr(let instance) = record.data,
                  let type = BonjourCatalog.serviceTypes.first(where: {
                      record.name.caseInsensitiveCompare("\($0).local") == .orderedSame
                  }) else { continue }
            let suffix = ".\(type).local"
            guard instance.lowercased().hasSuffix(suffix.lowercased()) else { continue }
            let name = String(instance.dropLast(suffix.count))
            guard !name.isEmpty else { continue }
            let key = instance.lowercased()
            found.append(BonjourService(name: name, type: type, address: address, port: ports[key], txt: texts[key] ?? [:]))
        }
        return found
    }
}
