import Testing
@testable import NagoNetCore

struct NeighborDiscoveryTests {
    @Test func readsMACFromNeighborAdvertisement() {
        let mac: [UInt8] = [0x3C, 0x7C, 0x3F, 1, 2, 3]
        // NA(136): type·code·cksum(4) + flags(4) + target(16) + TLLA 옵션(종류 2, 길이 1, MAC 6)
        let na: [UInt8] = [136, 0, 0, 0] + [0x20, 0, 0, 0] + [UInt8](repeating: 0, count: 16) + [2, 1] + mac
        #expect(NeighborDiscovery.mac(in: na) == MACAddress(mac))
    }

    @Test func readsMACFromNeighborSolicitation() {
        let mac: [UInt8] = [0xA6, 0x11, 0x22, 0x33, 0x44, 0x55]   // 무작위 MAC도 유효
        // NS(135): 4 + reserved(4) + target(16) + SLLA 옵션(종류 1, 길이 1, MAC)
        let ns: [UInt8] = [135, 0, 0, 0] + [0, 0, 0, 0] + [UInt8](repeating: 0, count: 16) + [1, 1] + mac
        #expect(NeighborDiscovery.mac(in: ns) == MACAddress(mac))
    }

    @Test func stripsLeadingIPv6HeaderAndIgnoresOthers() {
        let mac: [UInt8] = [0x3C, 0x7C, 0x3F, 9, 9, 9]
        let na: [UInt8] = [136, 0, 0, 0] + [0x20, 0, 0, 0] + [UInt8](repeating: 0, count: 16) + [2, 1] + mac
        let withHeader = [UInt8(0x60)] + [UInt8](repeating: 0, count: 39) + na   // 40바이트 IPv6 머리가 붙은 경우
        #expect(NeighborDiscovery.mac(in: withHeader) == MACAddress(mac))
        #expect(NeighborDiscovery.mac(in: [129, 0, 0, 0, 0, 0, 0, 0]) == nil)   // 에코 응답은 무시
        #expect(NeighborDiscovery.mac(in: []) == nil)
    }
}
