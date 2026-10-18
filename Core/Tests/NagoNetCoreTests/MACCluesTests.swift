import Foundation
import Testing
@testable import NagoNetCore

private func ipv6(_ groups: [UInt16]) -> IPv6Address {
    IPv6Address(groups.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] })!
}

private func http(_ body: String, status: String = "200 OK") -> [UInt8] {
    Array("HTTP/1.1 \(status)\r\nContent-Type: text/plain\r\n\r\n\(body)".utf8)
}

struct MACCluesTests {
    @Test func readsMACFromVersion1UUIDs() {
        // Hue 브리지의 UPnP UDN(버전 1, 노드 = 00:17:88:…)
        #expect(MACClues.mac(fromUUID: "uuid:2f402f80-da50-11e1-9b23-001788102201::upnp:rootdevice")?.description
                == "00:17:88:10:22:01")
        // 브라더 프린터의 IPP TXT UUID
        #expect(MACClues.mac(fromUUID: "e3248000-80ce-11db-8000-30055c773bcf")?.description == "30:05:5C:77:3B:CF")
        // Sonos
        #expect(MACClues.mac(fromUUID: "uuid:RINCON_000E58A1B2C301400")?.description == "00:0E:58:A1:B2:C3")
        // 버전 4(무작위)·무작위 노드(멀티캐스트 비트)·깨진 값은 MAC이 아니다
        #expect(MACClues.mac(fromUUID: "f47ac10b-58cc-4372-a567-0e02b2c3d479") == nil)
        #expect(MACClues.mac(fromUUID: "2f402f80-da50-11e1-9b23-011788102201") == nil)
        #expect(MACClues.mac(fromUUID: "uuid:not-a-uuid") == nil)
        #expect(MACClues.mac(fromUUID: "2f402f80-da50-11e1-9b23-000000000000") == nil)
    }

    @Test func readsMACFromEUI64IPv6() {
        let eui = ipv6([0xFE80, 0, 0, 0, 0x0211, 0x32FF, 0xFE12, 0x3456])
        #expect(eui.isLinkLocal)
        #expect(eui.embeddedMAC?.description == "00:11:32:12:34:56")
        #expect(eui.description == "fe80::211:32ff:fe12:3456")
        // 애플·윈도우·안드로이드처럼 무작위 인터페이스 ID면 MAC이 없다
        #expect(ipv6([0xFE80, 0, 0, 0, 0x1C2B, 0x3D4E, 0x5F60, 0x7182]).embeddedMAC == nil)
        #expect(ipv6([0x2001, 0xDB8, 0, 0, 0, 0, 0, 1]).description == "2001:db8::1")
        #expect(ipv6([0x2001, 0xDB8, 0, 1, 0, 0, 0, 1]).description == "2001:db8:0:1::1")
        #expect(ipv6([1, 0, 2, 0, 3, 0, 4, 0]).description == "1:0:2:0:3:0:4:0")
        #expect(IPv6Address([1, 2, 3]) == nil)
    }

    @Test func readsMACFromBonjourAdvertisements() {
        let ip = IPv4(192, 168, 0, 20)
        let disk = BonjourService(name: "DiskStation", type: "_adisk._tcp", address: ip,
                                  txt: ["sys": "waMa=00:11:32:AA:BB:CC,adVF=0x100", "dk0": "adVN=TimeMachine,adVF=0x82"])
        #expect(MACClues.mac(in: disk)?.description == "00:11:32:AA:BB:CC")
        // macOS 서버는 waMa=0
        #expect(MACClues.mac(in: BonjourService(name: "Mac", type: "_adisk._tcp", address: ip, txt: ["sys": "waMa=0,adVF=0x100"])) == nil)

        let workstation = BonjourService(name: "diskstation [00:11:32:aa:bb:cd]", type: "_workstation._tcp", address: ip)
        #expect(MACClues.mac(in: workstation)?.description == "00:11:32:AA:BB:CD")
        #expect(workstation.friendlyName == "diskstation")

        let sync = BonjourService(name: "a8:5c:2c:11:22:33@fe80::aa5c:2cff:fe11:2233", type: "_apple-mobdev2._tcp", address: ip)
        #expect(MACClues.mac(in: sync)?.description == "A8:5C:2C:11:22:33")
        #expect(sync.friendlyName == nil)

        let esphome = BonjourService(name: "living-room-plug", type: "_esphomelib._tcp", address: ip, txt: ["mac": "a4cf12345678"])
        #expect(MACClues.mac(in: esphome)?.description == "A4:CF:12:34:56:78")

        let hue = BonjourService(name: "Hue Bridge - 102201", type: "_hue._tcp", address: ip, txt: ["bridgeid": "001788fffe102201"])
        #expect(MACClues.mac(in: hue)?.description == "00:17:88:10:22:01")
        #expect(MACClues.mac(in: BonjourService(name: "x", type: "_hue._tcp", address: ip, txt: ["bridgeid": "0017881234"])) == nil)
        #expect(MACClues.mac(in: BonjourService(name: "x", type: "_ssh._tcp", address: ip)) == nil)
    }

    @Test func readsMACFromDeviceAPIs() {
        let roku = http("""
        <?xml version="1.0" encoding="UTF-8" ?>
        <device-info><udn>29380007-0800-1025-80a4-d83134a1b2c3</udn><wifi-mac>d8:31:34:a1:b2:c3</wifi-mac>\
        <ethernet-mac>d8:31:34:a1:b2:c4</ethernet-mac><network-type>ethernet</network-type></device-info>
        """)
        #expect(MACClues.rokuMAC(roku)?.description == "D8:31:34:A1:B2:C4")
        let wifiRoku = http("<device-info><wifi-mac>d8:31:34:a1:b2:c3</wifi-mac><network-type>wifi</network-type></device-info>")
        #expect(MACClues.rokuMAC(wifiRoku)?.description == "D8:31:34:A1:B2:C3")

        let samsung = http(#"{"device":{"modelName":"QN55Q60TAFXZA","networkType":"wireless","wifiMac":"70:2a:d5:11:22:33"},"name":"[TV] Samsung"}"#)
        #expect(MACClues.samsungTVMAC(samsung)?.description == "70:2A:D5:11:22:33")

        #expect(MACClues.hueMAC(http(#"{"name":"Hue Bridge","mac":"00:17:88:10:22:01","bridgeid":"001788FFFE102201"}"#))?
            .description == "00:17:88:10:22:01")
        // bridgeid가 없으면 Hue가 아니다(다른 기기의 /api/config)
        #expect(MACClues.hueMAC(http(#"{"mac":"00:17:88:10:22:01"}"#)) == nil)

        #expect(MACClues.shellyMAC(http(#"{"type":"SHSW-1","mac":"E868E7123456","auth":false}"#))?.description == "E8:68:E7:12:34:56")
        #expect(MACClues.shellyMAC(http(#"{"name":null,"id":"shellyplus1-a8032ab12345","mac":"A8032AB12345","gen":2}"#))?
            .description == "A8:03:2A:B1:23:45")
        #expect(MACClues.shellyMAC(http("not found", status: "404 Not Found")) == nil)
        #expect(MACClues.samsungTVMAC(http("<html>login</html>")) == nil)
    }

    @Test func readsUDNFromUPnPDescription() {
        let xml = http("""
        <root><device><friendlyName>Hue Bridge (192.168.0.20)</friendlyName><manufacturer>Signify</manufacturer>\
        <modelName>Philips hue bridge 2015</modelName><UDN>uuid:2f402f80-da50-11e1-9b23-001788102201</UDN></device></root>
        """)
        let upnp = SSDP.describe(xml, server: nil)
        #expect(upnp?.udn == "uuid:2f402f80-da50-11e1-9b23-001788102201")
        #expect(upnp?.macAddress == nil)
    }

    @Test func refreshesReportedMACsWithRegistryCheck() {
        var bridge = Device(address: IPv4(192, 168, 0, 20), responseTime: .milliseconds(4))
        bridge.upnp = UPnPDevice(friendlyName: "Hue Bridge", udn: "uuid:2f402f80-da50-11e1-9b23-001788102201")
        // 등록되지 않은 제조사 번호면(우연히 버전 1 꼴인 ID) 믿지 않는다
        let unregistered = bridge.refreshReportedMACs(isRegistered: { _ in false })
        #expect(!unregistered)
        #expect(bridge.mac == nil)
        let registered = bridge.refreshReportedMACs(isRegistered: { $0.oui == "001788" })
        #expect(registered)
        #expect(bridge.mac?.source == .deviceID)
        #expect(bridge.mac?.address.description == "00:17:88:10:22:01")
        // 다시 불러도 그대로면 false
        let again = bridge.refreshReportedMACs(isRegistered: { _ in true })
        #expect(!again)

        var printer = Device(address: IPv4(192, 168, 0, 30), responseTime: .milliseconds(4))
        printer.ipv6Addresses = [ipv6([0xFE80, 0, 0, 0, 0x3205, 0x5CFF, 0xFE77, 0x3BCF])]
        printer.refreshReportedMACs(isRegistered: { _ in true })
        #expect(printer.mac?.source == .ipv6)
        #expect(printer.mac?.address.description == "30:05:5C:77:3B:CF")

        // 기기에 직접 물은 SNMP MAC은 단서를 다시 읽어도 남고, 광고보다 먼저 믿는다
        printer.reportedMACs[.deviceSNMP] = MACAddress("30:05:5C:77:3B:CE")
        printer.merge(BonjourService(name: "Brother", type: "_ipp._tcp", address: printer.address,
                                     txt: ["uuid": "e3248000-80ce-11db-8000-30055c773bcf"]))
        printer.refreshReportedMACs(isRegistered: { _ in true })
        #expect(printer.reportedMACs[.deviceSNMP]?.description == "30:05:5C:77:3B:CE")
        #expect(printer.reportedMACs[.deviceID]?.description == "30:05:5C:77:3B:CF")
        #expect(printer.mac?.source == .deviceSNMP)

        // NetBIOS는 Bonjour 광고·기기 ID보다 먼저, 공유기 ARP 표는 무엇보다 먼저
        printer.reportedMACs = [:]
        printer.netbiosMAC = MACAddress("30:05:5C:00:00:01")
        printer.refreshReportedMACs(isRegistered: { _ in true })
        #expect(printer.mac?.source == .netbios)
        printer.routerMAC = MACAddress("30:05:5C:00:00:02")
        #expect(printer.mac?.source == .router)
    }
}

// MARK: mDNS AAAA

/// 질문 하나에 답 레코드들을 붙인 mDNS 답
private func dnsReply(id: UInt16, records: [(name: String, type: UInt16, data: [UInt8])]) -> [UInt8] {
    var bytes = DNSMessage.be16(id)
    bytes += [0x84, 0x00, 0, 0]
    bytes += DNSMessage.be16(UInt16(records.count))
    bytes += [0, 0, 0, 0]
    for record in records {
        bytes += DNSMessage.encode(name: record.name)
        bytes += DNSMessage.be16(record.type)
        bytes += DNSMessage.be16(0x8001)
        bytes += [0, 0, 0, 120]
        bytes += DNSMessage.be16(UInt16(record.data.count))
        bytes += record.data
    }
    return bytes
}

/// 질의의 (ID, 이름, 종류)
private func question(_ payload: [UInt8]) -> (UInt16, String, UInt16)? {
    guard let (name, next) = DNSMessage.readName(payload, at: 12), next + 2 <= payload.count else { return nil }
    return (DNSMessage.read16(payload, 0), name, DNSMessage.read16(payload, next))
}

private struct HostOnlyMDNS: DatagramExchanging {
    let host: String
    let address: [UInt8]

    func exchange(_ payload: [UInt8], with ip: IPv4, port: UInt16, timeout: Duration) async -> [UInt8]? {
        guard port == 5353, let (id, name, type) = question(payload) else { return nil }
        switch type {
        case DNSMessage.RecordType.ptr where name.hasSuffix("in-addr.arpa"):
            return dnsReply(id: id, records: [(name, DNSMessage.RecordType.ptr, DNSMessage.encode(name: host))])
        case DNSMessage.RecordType.aaaa where name == host:
            return dnsReply(id: id, records: [(host, DNSMessage.RecordType.aaaa, address)])
        default:
            return nil
        }
    }
}

private struct NoNames: HostNameResolving {
    func hostName(for address: IPv4) async -> String? { nil }
}

struct MDNSIPv6Tests {
    @Test func asksForAAAAAfterHostName() async {
        let address: [UInt8] = [0xFE, 0x80, 0, 0, 0, 0, 0, 0, 0x02, 0x11, 0x32, 0xFF, 0xFE, 0x12, 0x34, 0x56]
        let transport = HostOnlyMDNS(host: "printer.local", address: address)
        let names = await NameResolver(dns: NoNames(), transport: transport).names(for: IPv4(192, 168, 0, 30))
        #expect(names.mdnsName == "printer.local")
        #expect(names.ipv6.map(\.description) == ["fe80::211:32ff:fe12:3456"])

        var device = Device(address: IPv4(192, 168, 0, 30), responseTime: .milliseconds(2))
        device.merge(names)
        device.refreshReportedMACs(isRegistered: { _ in true })
        #expect(device.mac?.address.description == "00:11:32:12:34:56")
        #expect(device.mac?.source == .ipv6)
    }
}

// MARK: MACProber

/// 인터페이스가 둘인 가짜 SNMP 기기: 1번 루프백(MAC 없음), 2번 Wi-Fi
private struct FakeSNMPDevice: DatagramExchanging {
    let ip: IPv4
    let mac: [UInt8]
    var knowsAddressTable = true

    func exchange(_ payload: [UInt8], with host: IPv4, port: UInt16, timeout: Duration) async -> [UInt8]? {
        guard port == 161, let message = SNMP.readTLV(payload, at: 0) else { return nil }
        let fields = SNMP.readSequence(payload, message.range)
        guard fields.count == 3 else { return nil }
        let pdu = SNMP.readSequence(payload, fields[2].range)
        guard pdu.count == 4, let id = SNMP.decodeInteger(payload, pdu[0].range),
              let first = SNMP.readSequence(payload, pdu[3].range).first else { return nil }
        let oid = SNMP.decodeOID(Array(payload[SNMP.readSequence(payload, first.range)[0].range]))

        let rows: [([UInt32], [UInt8])]
        let addressOID = SNMP.addressInterface + ip.octets.map(UInt32.init)
        switch fields[2].tag {
        case 0xA0 where oid == addressOID && knowsAddressTable:
            rows = [(oid, SNMP.encodeInteger(2))]
        case 0xA0 where oid == SNMP.interfaceMAC + [2]:
            rows = [(oid, SNMP.tlv(0x04, mac))]
        case 0xA0:
            rows = [(oid, [0x81, 0x00])]   // noSuchInstance
        case 0xA5 where oid == SNMP.interfaceMAC:
            rows = [(SNMP.interfaceMAC + [1], SNMP.tlv(0x04, [])), (SNMP.interfaceMAC + [2], SNMP.tlv(0x04, mac))]
        default:
            return nil
        }
        var varBinds: [UInt8] = []
        for (rowOID, value) in rows {
            varBinds += SNMP.tlv(0x30, SNMP.encodeOID(rowOID) + value)
        }
        var pduBody = SNMP.encodeInteger(id)
        pduBody += SNMP.encodeInteger(0)
        pduBody += SNMP.encodeInteger(0)
        pduBody += SNMP.tlv(0x30, varBinds)
        var reply = SNMP.encodeInteger(1)
        reply += SNMP.tlv(0x04, Array("public".utf8))
        reply += SNMP.tlv(0xA2, pduBody)
        return SNMP.tlv(0x30, reply)
    }
}

private struct Silent: DatagramExchanging {
    func exchange(_ payload: [UInt8], with host: IPv4, port: UInt16, timeout: Duration) async -> [UInt8]? { nil }
}

private struct FakeAPIs: HTTPFetching {
    let pages: [String: String]
    func get(host: IPv4, port: UInt16, path: String, tls: Bool) async -> [UInt8]? {
        pages["\(port)\(path)"].map { http($0) }
    }
}

struct MACProberTests {
    let ip = IPv4(192, 168, 0, 40)
    let mac: [UInt8] = [0x30, 0x05, 0x5C, 0x77, 0x3B, 0xCF]

    @Test func asksDeviceSNMPForInterfaceMAC() async {
        let prober = MACProber(transport: FakeSNMPDevice(ip: ip, mac: mac), http: FakeAPIs(pages: [:]))
        let found = await prober.probe(ip, openPorts: [80, 9100], community: "public")
        #expect(found?.0.description == "30:05:5C:77:3B:CF")
        #expect(found?.1 == .deviceSNMP)
        // 커뮤니티가 없으면(SNMP 끔) 묻지 않는다
        #expect(await prober.probe(ip, openPorts: [80], community: nil) == nil)
    }

    @Test func fallsBackToFirstInterfaceMAC() async {
        let device = FakeSNMPDevice(ip: ip, mac: mac, knowsAddressTable: false)
        let found = await MACProber(transport: device, http: FakeAPIs(pages: [:])).probe(ip, openPorts: [], community: "public")
        #expect(found?.0.description == "30:05:5C:77:3B:CF")
    }

    @Test func asksDeviceAPIsWhenSNMPIsSilent() async {
        let roku = FakeAPIs(pages: ["8060/query/device-info": "<device-info><wifi-mac>d8:31:34:a1:b2:c3</wifi-mac></device-info>"])
        let found = await MACProber(transport: Silent(), http: roku).probe(ip, openPorts: [], community: "public")
        #expect(found?.0.description == "D8:31:34:A1:B2:C3")
        #expect(found?.1 == .deviceAPI)

        // Hue·Shelly는 웹 포트가 열린 기기만 묻는다
        let shelly = FakeAPIs(pages: ["80/shelly": #"{"type":"SHSW-1","mac":"E868E7123456"}"#])
        #expect(await MACProber(transport: Silent(), http: shelly).probe(ip, openPorts: [], community: nil) == nil)
        #expect(await MACProber(transport: Silent(), http: shelly).probe(ip, openPorts: [80], community: nil)?.0.description
                == "E8:68:E7:12:34:56")
        #expect(await MACProber(transport: Silent(), http: FakeAPIs(pages: [:])).probe(ip, openPorts: [80], community: "public") == nil)
    }
}
