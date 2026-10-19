import Foundation

/// 기기에 MAC을 물어보는 쪽. 앱은 `MACProber`, 시험은 가짜로.
public protocol MACProbing: Sendable {
    /// 찾은 MAC과 출처. 답이 없으면 nil
    func probe(_ address: IPv4, openPorts: [UInt16], community: String?) async -> (MACAddress, MACSource)?
}

/// 기기에 직접 물어 MAC을 알아낸다(기기가 누구에게나 답해 주는 것만, 읽기만 한다).
///
/// - **기기 SNMP**(UDP 161, 커뮤니티를 알 때): 그 IP가 붙은 인터페이스(ipAdEntIfIndex)의 ifPhysAddress.
///   프린터·NAS·관리형 AP·스위치가 흔히 public으로 답한다. 공유기 ARP 표와 달리 기기 자신에게 묻는다.
/// - **Roku**(TCP 8060 `/query/device-info`)·**삼성 TV**(TCP 8001 `/api/v2/`): 같은 Wi-Fi의 리모컨 앱에 여는 기기 정보
/// - **Hue 브리지**(`/api/config`)·**Shelly**(`/shelly`): 웹 포트(80)가 열린 기기만
public struct MACProber: MACProbing {
    private let transport: any DatagramExchanging
    private let http: any HTTPFetching
    private let timeout: Duration

    public init(transport: any DatagramExchanging, http: any HTTPFetching, timeout: Duration = .milliseconds(1200)) {
        self.transport = transport
        self.http = http
        self.timeout = timeout
    }

    /// SNMP와 API를 함께 묻고, 기기 SNMP(인터페이스 MAC)를 API보다 먼저 믿는다.
    public func probe(_ address: IPv4, openPorts: [UInt16], community: String?) async -> (MACAddress, MACSource)? {
        async let snmp = snmpMAC(of: address, community: community)
        async let api = apiMAC(of: address, webOpen: openPorts.contains(80))
        if let mac = await snmp { return (mac, .deviceSNMP) }
        if let mac = await api { return (mac, .deviceAPI) }
        return nil
    }

    /// 그 IP의 인터페이스 번호 → 그 인터페이스의 MAC. 번호 표가 없으면 인터페이스 MAC 표의 첫 진짜 MAC.
    func snmpMAC(of address: IPv4, community: String?) async -> MACAddress? {
        guard let community else { return nil }
        // 답이 아예 없으면 SNMP를 안 쓰는 기기라 더 묻지 않는다
        guard let index = await get(SNMP.addressInterface + address.octets.map(UInt32.init), from: address, community: community)
        else { return nil }
        if case .integer(let number) = index, let ifIndex = UInt32(exactly: number),
           case .octets(let bytes)? = await get(SNMP.interfaceMAC + [ifIndex], from: address, community: community),
           let mac = MACAddress(bytes) {
            return mac
        }
        let id = Int32.random(in: 1...Int32.max)
        let request = SNMP.getBulk(community: community, requestID: id, oid: SNMP.interfaceMAC, maxRepetitions: 8)
        guard let reply = await transport.exchange(request, with: address, port: 161, timeout: timeout),
              let rows = SNMP.parseResponse(reply, requestID: id) else { return nil }
        for row in rows where row.oid.starts(with: SNMP.interfaceMAC) {
            if case .octets(let bytes) = row.value, let mac = MACAddress(bytes) { return mac }
        }
        return nil
    }

    /// 값 하나. 답이 없으면 nil, 답은 왔는데 그 OID가 없으면 `.end`
    private func get(_ oid: [UInt32], from address: IPv4, community: String) async -> SNMP.Value? {
        let id = Int32.random(in: 1...Int32.max)
        guard let reply = await transport.exchange(SNMP.get(community: community, requestID: id, oids: [oid]),
                                                   with: address, port: 161, timeout: timeout),
              let rows = SNMP.parseResponse(reply, requestID: id) else { return nil }
        return rows.first { $0.oid == oid }?.value ?? .end
    }

    func apiMAC(of address: IPv4, webOpen: Bool) async -> MACAddress? {
        async let roku = fetch(address, port: 8060, path: "/query/device-info")
        async let samsung = fetch(address, port: 8001, path: "/api/v2/")
        async let hue = fetch(address, port: 80, path: "/api/config", when: webOpen)
        async let shelly = fetch(address, port: 80, path: "/shelly", when: webOpen)
        if let mac = await roku.flatMap(MACClues.rokuMAC) { return mac }
        if let mac = await samsung.flatMap(MACClues.samsungTVMAC) { return mac }
        if let mac = await hue.flatMap(MACClues.hueMAC) { return mac }
        return await shelly.flatMap(MACClues.shellyMAC)
    }

    private func fetch(_ address: IPv4, port: UInt16, path: String, when condition: Bool = true) async -> [UInt8]? {
        guard condition else { return nil }
        return await http.get(host: address, port: port, path: path, tls: false)
    }
}
