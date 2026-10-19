import Testing
@testable import NagoNetCore

/// DNS 답 바이트를 손으로 만든다(이름 압축 포인터 포함).
private struct ReplyBuilder {
    var bytes: [UInt8]
    private var records = 0

    init(id: UInt16, question: String? = nil) {
        bytes = DNSMessage.be16(id) + [0x84, 0x00] + DNSMessage.be16(question == nil ? 0 : 1) + [0, 0, 0, 0, 0, 0]
        if let question {
            bytes += DNSMessage.encode(name: question) + DNSMessage.be16(DNSMessage.RecordType.ptr) + DNSMessage.be16(1)
        }
    }

    /// 지금 끝 위치(나중 레코드가 압축 포인터로 가리킬 수 있게)
    var offset: Int { bytes.count }

    mutating func add(name: [UInt8], type: UInt16, data: [UInt8]) {
        let ttl: [UInt8] = [0, 0, 0x11, 0x94]
        bytes += name
        bytes += DNSMessage.be16(type)
        bytes += DNSMessage.be16(0x8001)   // IN + 캐시 비우기 비트
        bytes += ttl
        bytes += DNSMessage.be16(UInt16(data.count))
        bytes += data
        records += 1
        bytes.replaceSubrange(6..<8, with: DNSMessage.be16(UInt16(records)))
    }

    static func pointer(_ offset: Int) -> [UInt8] { [0xC0 | UInt8(offset >> 8), UInt8(offset & 0xFF)] }
}

/// 주소·포트별로 미리 정한 답을 돌려주는 가짜 UDP.
private struct FakeTransport: DatagramExchanging {
    var replies: [UInt16: @Sendable ([UInt8]) -> [UInt8]?] = [:]

    func exchange(_ payload: [UInt8], with host: IPv4, port: UInt16, timeout: Duration) async -> [UInt8]? {
        replies[port]?(payload)
    }
}

private struct FixedDNS: HostNameResolving {
    var name: String?
    func hostName(for address: IPv4) async -> String? { name }
}

private func queryID(_ payload: [UInt8]) -> UInt16 { UInt16(payload[0]) << 8 | UInt16(payload[1]) }

struct DNSMessageTests {
    @Test func buildsQueryWithQuestions() {
        let query = DNSMessage.query(id: 0xBEEF, questions: [("_airplay._tcp.local", 12), ("7.0.168.192.in-addr.arpa", 12)])
        #expect(Array(query.prefix(6)) == [0xBE, 0xEF, 0, 0, 0, 2])
        #expect(Array(query[12..<21]) == [8] + Array("_airplay".utf8))
        #expect(DNSMessage.reverseName(for: IPv4(192, 168, 0, 7)) == "7.0.168.192.in-addr.arpa")
    }

    @Test func parsesCompressedPTRSRVTXTAndA() {
        var reply = ReplyBuilder(id: 7)
        let typeOffset = reply.offset
        let instance = Array("민지의 iPhone".utf8)
        // _companion-link._tcp.local PTR → "민지의 iPhone" + (포인터: 앞의 서비스 이름)
        reply.add(name: DNSMessage.encode(name: "_companion-link._tcp.local"), type: 12,
                  data: [UInt8(instance.count)] + instance + ReplyBuilder.pointer(typeOffset))
        let instanceOffset = reply.offset - (1 + instance.count + 2)
        reply.add(name: ReplyBuilder.pointer(instanceOffset), type: 33,
                  data: [0, 0, 0, 0, 0xC0, 0x31] + DNSMessage.encode(name: "Minjis-iPhone.local"))
        reply.add(name: ReplyBuilder.pointer(instanceOffset), type: 16,
                  data: [8] + Array("rpMd=x,1".utf8) + [4] + Array("flag".utf8))
        reply.add(name: DNSMessage.encode(name: "Minjis-iPhone.local"), type: 1, data: [192, 168, 0, 33])

        let records = DNSMessage.records(in: reply.bytes, id: 7)
        #expect(records.count == 4)
        #expect(records[0].data == .ptr("민지의 iPhone._companion-link._tcp.local"))
        #expect(records[1].name == "민지의 iPhone._companion-link._tcp.local")
        #expect(records[1].data == .srv(port: 0xC031, target: "Minjis-iPhone.local"))
        #expect(records[2].data == .txt(["rpmd": "x,1", "flag": ""]))
        #expect(records[3].data == .a(IPv4(192, 168, 0, 33)))
    }

    @Test func rejectsWrongIDQueriesAndGarbage() {
        var reply = ReplyBuilder(id: 1)
        reply.add(name: DNSMessage.encode(name: "a.local"), type: 1, data: [1, 2, 3, 4])
        #expect(DNSMessage.records(in: reply.bytes, id: 2).isEmpty)
        #expect(DNSMessage.records(in: DNSMessage.query(id: 1, questions: [("a.local", 1)])).isEmpty)
        #expect(DNSMessage.records(in: [0, 1, 0x84]).isEmpty)
        // 자기 자신을 가리키는 압축 포인터(무한 반복)
        let loop: [UInt8] = [0, 1, 0x84, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0xC0, 12]
        #expect(DNSMessage.records(in: loop).isEmpty)
        // 길이가 남은 바이트보다 긴 레코드는 버린다
        var truncated = reply.bytes
        truncated.removeLast(2)
        #expect(DNSMessage.records(in: truncated).isEmpty)
    }

    @Test func netbiosRequestMatchesWireFormat() {
        let request = NetBIOS.nodeStatusRequest(id: 0x1234)
        #expect(request.count == 50)
        #expect(Array(request[12..<15]) == [0x20, 0x43, 0x4B])   // 길이 32, "*" → "CK"
        #expect(Array(request[15..<45]) == [UInt8](repeating: 0x41, count: 30))
        #expect(Array(request[46..<50]) == [0, 0x21, 0, 1])
    }

    @Test func netbiosPicksWorkstationName() {
        func entry(_ name: String, _ suffix: UInt8, group: Bool) -> [UInt8] {
            let padded = Array(name.utf8) + [UInt8](repeating: 0x20, count: 15 - name.utf8.count)
            return padded + [suffix, group ? 0x84 : 0x04, 0x00]
        }
        let names = entry("WORKGROUP", 0x00, group: true) + entry("MINJI-PC", 0x20, group: false)
            + entry("MINJI-PC", 0x00, group: false)
        let data = [3] + names + [UInt8](repeating: 0, count: 46)
        var reply: [UInt8] = [0x12, 0x34, 0x84, 0x00, 0, 0, 0, 1, 0, 0, 0, 0]
        reply += Array(NetBIOS.nodeStatusRequest(id: 0)[12..<46])
        reply += [0, 0x21, 0, 1, 0, 0, 0, 0] + DNSMessage.be16(UInt16(data.count)) + data
        #expect(NetBIOS.computerName(in: reply) == "MINJI-PC")
        #expect(NetBIOS.computerName(in: Array(reply.prefix(60))) == nil)
        #expect(NetBIOS.computerName(in: []) == nil)
    }
}

struct NameResolverTests {
    private let ip = IPv4(192, 168, 0, 33)

    @Test func combinesAllSources() async {
        var transport = FakeTransport()
        let reverse = DNSMessage.reverseName(for: ip)
        transport.replies[5353] = { query in
            var reply = ReplyBuilder(id: queryID(query))
            let questions = Int(query[5])
            let firstType = query.count >= 4 ? UInt16(query[query.count - 4]) << 8 | UInt16(query[query.count - 3]) : 0
            if questions == 1, firstType == DNSMessage.RecordType.ptr {
                // 역방향 PTR 질의
                reply.add(name: DNSMessage.encode(name: reverse), type: 12, data: DNSMessage.encode(name: "Minjis-iPhone.local"))
            } else if firstType == DNSMessage.RecordType.txt {
                // 두 번째 질의: TXT·_device-info
                reply.add(name: DNSMessage.encode(name: "Living Room._device-info._tcp.local"), type: 16,
                          data: [15] + Array("model=iPad13,18".utf8))
            } else {
                reply.add(name: DNSMessage.encode(name: "_airplay._tcp.local"), type: 12,
                          data: DNSMessage.encode(name: "Living Room._airplay._tcp.local"))
                reply.add(name: DNSMessage.encode(name: "Living Room._airplay._tcp.local"), type: 33,
                          data: [0, 0, 0, 0, 0x1B, 0x58] + DNSMessage.encode(name: "Apple-TV.local"))
                reply.add(name: DNSMessage.encode(name: "Living Room._airplay._tcp.local"), type: 16,
                          data: [17] + Array("model=AppleTV14,1".utf8))
                // 모르는 종류는 버린다
                reply.add(name: DNSMessage.encode(name: "_sleep-proxy._udp.local"), type: 12,
                          data: DNSMessage.encode(name: "x._sleep-proxy._udp.local"))
            }
            return reply.bytes
        }
        let resolver = NameResolver(dns: FixedDNS(name: "iphone-33.lan"), transport: transport)
        let names = await resolver.names(for: ip)
        #expect(names.dnsName == "iphone-33.lan")
        #expect(names.mdnsName == "Minjis-iPhone.local")
        #expect(names.netbiosName == nil)
        #expect(names.services == [
            BonjourService(name: "Living Room", type: "_airplay._tcp", address: ip, port: 7000, txt: ["model": "AppleTV14,1"]),
        ])
        #expect(names.model == "iPad13,18")

        var device = Device(address: ip, responseTime: .milliseconds(9))
        device.merge(names)
        #expect(device.name == "Living Room")
        #expect(device.displayHostName == "Minjis-iPhone")
        #expect(!device.needsNames)
    }

    @Test func silentDeviceGivesNothing() async {
        let resolver = NameResolver(dns: FixedDNS(name: nil), transport: FakeTransport())
        let names = await resolver.names(for: ip)
        #expect(names == DeviceNames())
        var device = Device(address: ip)
        device.merge(names)
        #expect(device.needsNames)
        #expect(device.name == nil)
    }

    @Test func hostNamePriorityPrefersDeviceProvidedNames() {
        var device = Device(address: ip)
        device.hostName = "dhcp-33.lan"
        #expect(device.name == "dhcp-33")
        device.netbiosName = "MINJI-PC"
        #expect(device.name == "MINJI-PC")
        device.mdnsName = "minji-desktop.local."
        #expect(device.name == "minji-desktop")
        // 새 조회에서 못 찾은 이름은 지우지 않는다
        device.merge(DeviceNames(dnsName: "new.lan"))
        #expect(device.mdnsName == "minji-desktop.local.")
        #expect(device.hostName == "new.lan")
    }
}
