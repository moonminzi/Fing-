import Testing
@testable import NagoNetCore

struct MACTests {
    @Test func parsesCommonFormats() {
        let mac = MACAddress("a4:83:e7:1:2:ff")
        #expect(mac?.description == "A4:83:E7:01:02:FF")
        #expect(MACAddress("A4-83-E7-01-02-FF") == mac)
        #expect(MACAddress("A483E70102FF") == mac)
        #expect(mac?.oui == "A483E7")
        #expect(MACAddress("00:00:00:00:00:00") == nil)
        #expect(MACAddress("FF:FF:FF:FF:FF:FF") == nil)
        // iOS가 가린 자리표시자(뒤 5바이트가 모두 0)는 MAC이 아니다
        #expect(MACAddress("02:00:00:00:00:00") == nil)
        #expect(MACAddress([0x06, 0, 0, 0, 0, 0]) == nil)
        #expect(MACAddress("02:00:00:00:00:01") != nil)
        #expect(MACAddress("A4:83:E7:01:02") == nil)
        #expect(MACAddress("G4:83:E7:01:02:FF") == nil)
    }

    @Test func randomizedAddressesHaveNoVendor() {
        let db = OUIDatabase(text: "# 주석\nA483E7\tApple\n001132\tSynology\n")
        #expect(db.count == 2)
        #expect(db.vendor(for: MACAddress("a4:83:e7:01:02:03")!) == "Apple")
        // 비공개 Wi-Fi 주소(두 번째 비트가 켜짐)
        let random = MACAddress("A6:83:E7:01:02:03")!
        #expect(random.isRandomized)
        #expect(db.vendor(for: random) == nil)
        #expect(db.vendor(for: MACAddress("00:11:33:00:00:01")!) == nil)
    }

    @Test func netbiosReplyCarriesMAC() {
        func entry(_ name: String, _ suffix: UInt8) -> [UInt8] {
            Array(name.utf8) + [UInt8](repeating: 0x20, count: 15 - name.utf8.count) + [suffix, 0x04, 0x00]
        }
        let mac: [UInt8] = [0x3C, 0x7C, 0x3F, 0x11, 0x22, 0x33]
        let data = [1] + entry("MINJI-PC", 0x00) + mac + [UInt8](repeating: 0, count: 40)
        var reply: [UInt8] = [0x12, 0x34, 0x84, 0x00, 0, 0, 0, 1, 0, 0, 0, 0]
        reply += Array(NetBIOS.nodeStatusRequest(id: 0)[12..<46])
        reply += [0, 0x21, 0, 1, 0, 0, 0, 0] + DNSMessage.be16(UInt16(data.count)) + data
        let status = NetBIOS.nodeStatus(in: reply)
        #expect(status?.name == "MINJI-PC")
        #expect(status?.mac == MACAddress(mac))
        // 삼바는 MAC 자리가 0
        var samba = reply
        samba.replaceSubrange((reply.count - 46)..<(reply.count - 40), with: [0, 0, 0, 0, 0, 0])
        #expect(NetBIOS.nodeStatus(in: samba)?.mac == nil)
    }

    @Test func deviceLearnsMACFromAirPlayAndPrefersRouter() {
        let ip = IPv4(192, 168, 10, 40)
        var tv = Device(address: ip, responseTime: .milliseconds(4))
        tv.merge(BonjourService(name: "거실", type: "_airplay._tcp", address: ip, txt: ["deviceid": "A4:83:E7:AA:BB:CC"]))
        #expect(tv.mac?.address == MACAddress("A4:83:E7:AA:BB:CC"))
        #expect(tv.mac?.source == .airplay)
        tv.routerMAC = MACAddress("A4:83:E7:AA:BB:CD")
        #expect(tv.mac?.source == .router)

        var speaker = Device(address: ip)
        speaker.merge(BonjourService(name: "A483E7112233@주방", type: "_raop._tcp", address: ip))
        #expect(speaker.airplayMAC == MACAddress("A4:83:E7:11:22:33"))
    }

    @Test func matcherUsesMACFirst() {
        let mac = MACAddress("3C:7C:3F:11:22:33")!
        let known = [DeviceIdentity(address: IPv4(10, 0, 0, 5), hostName: nil, bonjourName: nil, mac: mac)]
        // IP가 바뀌고 이름도 없어도 MAC으로 같은 기기
        #expect(DeviceMatcher.match(DeviceIdentity(address: IPv4(10, 0, 0, 9), hostName: nil, bonjourName: nil, mac: mac),
                                    against: known) == 0)
        // 같은 IP라도 MAC이 다르면 다른 기기
        let other = DeviceIdentity(address: IPv4(10, 0, 0, 5), hostName: nil, bonjourName: nil, mac: MACAddress("3C:7C:3F:99:99:99"))
        #expect(DeviceMatcher.match(other, against: known) == nil)
        #expect(known[0].keys(network: "n").first == "mac:3C:7C:3F:11:22:33")
    }

    @Test func randomizedMACIsAUsableIdentityKey() {
        var phone = Device(address: IPv4(10, 0, 0, 7), responseTime: .milliseconds(30))
        phone.routerMAC = MACAddress("A6:00:00:00:00:01")
        // 무작위 MAC도 식별에 쓴다: DHCP·공유기로 잡으면 그 네트워크 안에선 고정이라 IP가 바뀌어도 같은 기기로 추적
        #expect(phone.identity.mac == MACAddress("A6:00:00:00:00:01"))
        #expect(phone.kind == .phone)
        #expect(phone.classification.reasons == ["무작위 MAC(비공개 Wi-Fi 주소)를 쓰는 휴대기기"])
    }

    @Test func vendorDrivesKindAndName() {
        var nas = Device(address: IPv4(10, 0, 0, 8), responseTime: .milliseconds(2))
        nas.routerMAC = MACAddress("00:11:32:00:00:01")
        nas.macVendor = "Synology"
        #expect(nas.kind == .nas)
        #expect(nas.name == "Synology NAS")
        var phone = Device(address: IPv4(10, 0, 0, 9), responseTime: .milliseconds(2))
        phone.routerMAC = MACAddress("64:CC:2E:00:00:01")
        phone.macVendor = "Samsung Electronics"
        #expect(phone.kind == .unknown)   // 삼성은 휴대폰·TV를 다 만들어 짐작하지 않는다
        #expect(phone.name == "Samsung Electronics")
    }
}

struct SSDPTests {
    private let ip = IPv4(192, 168, 10, 30)

    @Test func searchRequestIsUnicastToDevice() {
        let text = String(decoding: SSDP.searchRequest(to: ip), as: UTF8.self)
        #expect(text.hasPrefix("M-SEARCH * HTTP/1.1\r\nHOST: 192.168.10.30:1900\r\n"))
        #expect(text.contains("MAN: \"ssdp:discover\"\r\n"))
        #expect(text.hasSuffix("\r\n\r\n"))
    }

    @Test func parsesResponseAndGuardsLocation() {
        let response = "HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=1800\r\nLOCATION: http://192.168.10.30:7676/smp_14_\r\nSERVER: SHP, UPnP/1.0, Samsung UPnP SDK/1.0\r\nST: upnp:rootdevice\r\n\r\n"
        let parsed = SSDP.parseResponse(Array(response.utf8))
        #expect(parsed?.location == "http://192.168.10.30:7676/smp_14_")
        #expect(parsed?.server == "SHP, UPnP/1.0, Samsung UPnP SDK/1.0")
        let target = SSDP.descriptionTarget("http://192.168.10.30:7676/smp_14_", expectedHost: ip)
        #expect(target?.port == 7676)
        #expect(target?.path == "/smp_14_")
        #expect(target?.tls == false)
        #expect(SSDP.descriptionTarget("http://192.168.10.31/desc.xml", expectedHost: ip) == nil)   // 다른 기기
        #expect(SSDP.descriptionTarget("ftp://192.168.10.30/x", expectedHost: ip) == nil)
        #expect(SSDP.descriptionTarget("https://192.168.10.30/d.xml?x=1", expectedHost: ip)?.path == "/d.xml?x=1")
        #expect(SSDP.parseResponse(Array("HTTP/1.1 404 Not Found\r\n\r\n".utf8)) == nil)
    }

    @Test func describesDeviceXML() {
        let xml = """
        HTTP/1.1 200 OK\r\nContent-Type: text/xml\r\n\r\n<?xml version="1.0"?>
        <root xmlns="urn:schemas-upnp-org:device-1-0"><device>
          <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
          <friendlyName>[TV] Samsung 7 Series (55)</friendlyName>
          <manufacturer>Samsung Electronics</manufacturer>
          <modelName>UN55TU7000</modelName>
          <deviceList><device><friendlyName>Sub</friendlyName></device></deviceList>
        </device></root>
        """
        let device = SSDP.describe(Array(xml.utf8), server: "SHP, UPnP/1.0")
        #expect(device?.friendlyName == "[TV] Samsung 7 Series (55)")
        #expect(device?.shortType == "MediaRenderer")
        #expect(device?.model == "Samsung Electronics UN55TU7000")

        var tv = Device(address: ip, responseTime: .milliseconds(5))
        tv.upnp = device
        #expect(tv.name == "[TV] Samsung 7 Series (55)")
        #expect(tv.kind == .tv)
        #expect(SSDP.describe(Array("HTTP/1.1 200 OK\r\n\r\n<root></root>".utf8), server: nil) == nil)
    }

    @Test func gatewayDescriptionMeansRouter() {
        var router = Device(address: ip, responseTime: .milliseconds(5))
        router.upnp = UPnPDevice(friendlyName: "Wireless Router", manufacturer: "EFM Networks",
                                 deviceType: "urn:schemas-upnp-org:device:InternetGatewayDevice:1")
        #expect(router.kind == .router)
    }
}

/// UDP 포트별로 답을 지어내는 가짜.
private struct ScriptedTransport: DatagramExchanging {
    let reply: @Sendable (UInt16, [UInt8]) -> [UInt8]?
    func exchange(_ payload: [UInt8], with host: IPv4, port: UInt16, timeout: Duration) async -> [UInt8]? {
        reply(port, payload)
    }
}

private struct FakeHTTP: HTTPFetching {
    let body: String
    func get(host: IPv4, port: UInt16, path: String, tls: Bool) async -> [UInt8]? {
        path == "/desc.xml" && port == 49152 ? Array(body.utf8) : nil
    }
}

private struct NoDNS: HostNameResolving {
    func hostName(for address: IPv4) async -> String? { nil }
}

struct NameResolverUPnPTests {
    @Test func resolvesUPnPThroughSSDPAndHTTP() async {
        let ip = IPv4(192, 168, 10, 50)
        let transport = ScriptedTransport { port, _ in
            port == 1900 ? Array("HTTP/1.1 200 OK\r\nLOCATION: http://192.168.10.50:49152/desc.xml\r\nSERVER: Linux UPnP/1.0 Sonos/70.3\r\n\r\n".utf8) : nil
        }
        let http = FakeHTTP(body: "HTTP/1.0 200 OK\r\n\r\n<root><device><deviceType>urn:schemas-upnp-org:device:ZonePlayer:1</deviceType><friendlyName>거실 - Sonos One</friendlyName><manufacturer>Sonos, Inc.</manufacturer><modelName>Sonos One</modelName></device></root>")
        let names = await NameResolver(dns: NoDNS(), transport: transport, http: http).names(for: ip)
        #expect(names.upnp?.friendlyName == "거실 - Sonos One")
        #expect(names.upnp?.server == "Linux UPnP/1.0 Sonos/70.3")
        var device = Device(address: ip, responseTime: .milliseconds(3))
        device.merge(names)
        #expect(device.kind == .speaker)
        #expect(device.name == "거실 - Sonos One")
        // http가 없으면 SSDP를 하지 않는다
        #expect(await NameResolver(dns: NoDNS(), transport: transport).names(for: ip).upnp == nil)
    }
}

/// ARP 표를 가진 가짜 SNMP 공유기(GetBulk를 진짜로 풀어서 다음 줄들을 돌려준다).
private struct FakeSNMPAgent {
    let community: String
    let table: [(IPv4, [UInt8])]
    let base: [UInt32]

    private var rows: [([UInt32], [UInt8])] {
        table.map { ip, mac in
            let suffix: [UInt32] = base == SNMP.arpTable ? [2] + ip.octets.map(UInt32.init)
                : [2, 1, 4] + ip.octets.map(UInt32.init)
            return (base + suffix, mac)
        }.sorted { $0.0.lexicographicallyPrecedes($1.0) }
    }

    func answer(_ request: [UInt8]) -> [UInt8]? {
        guard let message = SNMP.readTLV(request, at: 0) else { return nil }
        let fields = SNMP.readSequence(request, message.range)
        guard fields.count == 3, String(decoding: request[fields[1].range], as: UTF8.self) == community else { return nil }
        let pdu = SNMP.readSequence(request, fields[2].range)
        let id = SNMP.decodeInteger(request, pdu[0].range)!
        let maxRepetitions = Int(SNMP.decodeInteger(request, pdu[2].range)!)
        let varBind = SNMP.readSequence(request, SNMP.readSequence(request, pdu[3].range)[0].range)
        let start = SNMP.decodeOID(Array(request[varBind[0].range]))
        var out: [[UInt8]] = []
        for (oid, mac) in rows where start.lexicographicallyPrecedes(oid) {
            out.append(SNMP.tlv(0x30, SNMP.encodeOID(oid) + SNMP.tlv(0x04, mac)))
            if out.count == maxRepetitions { break }
        }
        if out.count < maxRepetitions {
            out.append(SNMP.tlv(0x30, SNMP.encodeOID(start + [9, 9]) + [0x82, 0x00]))   // 표 끝
        }
        let response = SNMP.tlv(0xA2, SNMP.encodeInteger(id) + SNMP.encodeInteger(0) + SNMP.encodeInteger(0)
            + SNMP.tlv(0x30, out.flatMap { $0 }))
        return SNMP.tlv(0x30, SNMP.encodeInteger(1) + SNMP.tlv(0x04, Array(community.utf8)) + response)
    }
}

struct SNMPTests {
    @Test func berRoundTrips() {
        #expect(SNMP.encodeInteger(0) == [0x02, 0x01, 0x00])
        #expect(SNMP.encodeInteger(128) == [0x02, 0x02, 0x00, 0x80])
        #expect(SNMP.encodeInteger(-1) == [0x02, 0x01, 0xFF])
        #expect(SNMP.encodeLength(200) == [0x81, 200])
        let oid: [UInt32] = [1, 3, 6, 1, 2, 1, 4, 22, 1, 2, 3, 192, 168, 10, 200]
        let encoded = SNMP.encodeOID(oid)
        #expect(Array(encoded.prefix(3)) == [0x06, UInt8(encoded.count - 2), 0x2B])
        #expect(SNMP.decodeOID(Array(encoded.dropFirst(2))) == oid)
        #expect(SNMP.decodeInteger([0xFF, 0x7F], 0..<2) == -129)
    }

    @Test func readsWholeARPTableAcrossPages() async {
        let table = (1...60).map { i in (IPv4(192, 168, 10, UInt8(i)), [0x00, 0x11, 0x32, 0x00, 0x00, UInt8(i)]) }
        let agent = FakeSNMPAgent(community: "public", table: table, base: SNMP.arpTable)
        let reader = ARPTableReader(transport: ScriptedTransport { port, payload in port == 161 ? agent.answer(payload) : nil })
        let result = await reader.read(from: IPv4(192, 168, 10, 1), community: "public")
        #expect(result?.count == 60)
        #expect(result?[IPv4(192, 168, 10, 42)] == MACAddress([0x00, 0x11, 0x32, 0x00, 0x00, 42]))
        // 커뮤니티가 틀리면 답이 없다
        #expect(await reader.read(from: IPv4(192, 168, 10, 1), community: "wrong") == nil)
    }

    @Test func fallsBackToNewerIPNetToPhysicalTable() async {
        let agent = FakeSNMPAgent(community: "c", table: [(IPv4(10, 0, 0, 7), [0x3C, 0x7C, 0x3F, 1, 2, 3])],
                                  base: SNMP.physicalTable)
        // 옛 표 질문엔 표 끝만, 새 표 질문엔 줄을 준다
        let transport = ScriptedTransport { _, payload in
            let text = SNMP.encodeOID(SNMP.arpTable)
            let asksOld = payload.firstRange(of: text) != nil
            if asksOld {
                return FakeSNMPAgent(community: "c", table: [], base: SNMP.arpTable).answer(payload)
            }
            return agent.answer(payload)
        }
        let result = await ARPTableReader(transport: transport).read(from: IPv4(10, 0, 0, 1), community: "c")
        #expect(result == [IPv4(10, 0, 0, 7): MACAddress([0x3C, 0x7C, 0x3F, 1, 2, 3])!])
    }
}
