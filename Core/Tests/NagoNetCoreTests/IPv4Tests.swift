import Testing
@testable import NagoNetCore

struct IPv4Tests {
    @Test func parsesDottedQuad() {
        #expect(IPv4("192.168.0.1") == IPv4(192, 168, 0, 1))
        #expect(IPv4("192.168.0.1")?.value == 0xC0A8_0001)
        #expect(IPv4("0.0.0.0") == IPv4(0))
        #expect(IPv4("255.255.255.255") == IPv4(0xFFFF_FFFF))
    }

    @Test(arguments: ["", "1.2.3", "1.2.3.4.5", "256.0.0.1", "1..2.3", "a.b.c.d", "+1.2.3.4", "1.2.3.4 ", "1234.1.1.1", "١.٢.٣.٤"])
    func rejectsMalformed(_ text: String) {
        #expect(IPv4(text) == nil)
    }

    @Test func formatsAndRoundTrips() {
        let ip = IPv4(10, 0, 42, 7)
        #expect(ip.description == "10.0.42.7")
        #expect(IPv4(ip.description) == ip)
        #expect(ip.octets == [10, 0, 42, 7])
    }

    @Test func networkByteOrder() {
        // 192.168.1.2를 네트워크 순서로 담은 s_addr를 리틀 엔디언 기계에서 읽으면 0x0201A8C0
        let ip = IPv4(networkOrder: UInt32(0xC0A8_0102).bigEndian)
        #expect(ip == IPv4(192, 168, 1, 2))
        #expect(ip.networkOrder == UInt32(0xC0A8_0102).bigEndian)
    }

    @Test func ordersAndStrides() {
        #expect(IPv4(10, 0, 0, 2) < IPv4(10, 0, 1, 0))
        let range = IPv4(192, 168, 0, 254)...IPv4(192, 168, 1, 1)
        #expect(range.map(\.description) == ["192.168.0.254", "192.168.0.255", "192.168.1.0", "192.168.1.1"])
        #expect(range.count == 4)
    }

    @Test func specialRanges() {
        #expect(IPv4(169, 254, 3, 9).isLinkLocal)
        #expect(!IPv4(169, 253, 3, 9).isLinkLocal)
        #expect(IPv4(127, 0, 0, 1).isLoopback)
    }
}
