import Testing
@testable import NagoNetCore

struct ARPCacheTests {
    private func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }

    /// sockaddr_in(16바이트): len, AF_INET(2), port(2), IP(4), 0×8
    private func inet(_ ip: IPv4) -> [UInt8] { [16, 2, 0, 0] + ip.octets + [UInt8](repeating: 0, count: 8) }

    /// sockaddr_dl: len, AF_LINK(18), index(2), type, nlen, alen, slen, data(name + mac). 이름 없이 MAC만.
    private func link(_ mac: [UInt8], name: [UInt8] = [], alen: UInt8 = 6) -> [UInt8] {
        let data = name + mac
        return [UInt8(8 + data.count), 18, 0, 0, 6, UInt8(name.count), alen, 0] + data
    }

    private func padded(_ sockaddr: [UInt8]) -> [UInt8] {
        let length = Int(sockaddr[0])
        let size = length > 0 ? 1 + ((length - 1) | 3) : 4
        return sockaddr + [UInt8](repeating: 0, count: size - sockaddr.count)
    }

    private func message(index: UInt16 = 6, _ slots: [Int: [UInt8]]) -> [UInt8] {
        var addrs: UInt32 = 0
        var tail: [UInt8] = []
        for slot in slots.keys.sorted() {
            addrs |= 1 << UInt32(slot)
            tail += padded(slots[slot]!)
        }
        var header: [UInt8] = le16(0)
        header += [5, 4]                      // rtm_version, rtm_type
        header += le16(index) + [0, 0]        // rtm_index + 맞춤용 빈칸
        header += [0, 0, 0, 0]                // rtm_flags
        header += [UInt8(addrs & 0xFF), UInt8(addrs >> 8 & 0xFF), 0, 0]   // rtm_addrs
        header += [UInt8](repeating: 0, count: RouteTable.headerSize - header.count)
        var bytes = header + tail
        bytes.replaceSubrange(0..<2, with: le16(UInt16(bytes.count)))
        return bytes
    }

    @Test func parsesIPToMAC() {
        let mac: [UInt8] = [0x3C, 0x7C, 0x3F, 0x11, 0x22, 0x33]
        let bytes = message([0: inet(IPv4(192, 168, 0, 7)), 1: link(mac)])
            + message([0: inet(IPv4(192, 168, 0, 1)), 1: link([0xA4, 0x83, 0xE7, 1, 2, 3], name: Array("en0".utf8))])
        let table = ARPCache.parse(bytes)
        #expect(table.count == 2)
        #expect(table[IPv4(192, 168, 0, 7)] == MACAddress(mac))
        #expect(table[IPv4(192, 168, 0, 1)] == MACAddress([0xA4, 0x83, 0xE7, 1, 2, 3]))
    }

    @Test func skipsZeroedAndIncompleteMACs() {
        // iOS가 MAC을 0으로 지운 항목
        let zeroed = message([0: inet(IPv4(10, 0, 0, 5)), 1: link([0, 0, 0, 0, 0, 0])])
        // 주소 길이가 6이 아님(이더넷 아님)
        let notEthernet = message([0: inet(IPv4(10, 0, 0, 6)), 1: link([1, 2, 3, 4, 5, 6, 7, 8], alen: 8)])
        #expect(ARPCache.parse(zeroed).isEmpty)
        #expect(ARPCache.parse(notEthernet).isEmpty)
        #expect(ARPCache.parse([]).isEmpty)
        // 잘려도 멈춘다(무한 반복 없이)
        #expect(ARPCache.parse([0xFF, 0xFF, 5, 4]).isEmpty)
    }

    @Test func deviceLearnsMACFromLocalARP() {
        var device = Device(address: IPv4(192, 168, 0, 7), responseTime: .milliseconds(5))
        device.localARPMAC = MACAddress([0x3C, 0x7C, 0x3F, 0x11, 0x22, 0x33])
        #expect(device.mac?.source == .localARP)
        // 공유기 SNMP가 있으면 그게 우선
        device.routerMAC = MACAddress([0x3C, 0x7C, 0x3F, 0x11, 0x22, 0x34])
        #expect(device.mac?.source == .router)
    }

    #if canImport(Darwin)
    @Test func readsRealARPCacheWithoutCrashing() throws {
        let table = try #require(ARPCache.read())
        // 어떤 항목이 오든 MAC은 올바른 6바이트여야 한다(iOS는 빈 표일 수도 있다)
        for (_, mac) in table {
            #expect(mac.bytes.count == 6)
        }
    }
    #endif
}
