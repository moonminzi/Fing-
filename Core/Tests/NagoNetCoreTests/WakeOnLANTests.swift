import Testing
@testable import NagoNetCore

struct WakeOnLANTests {
    @Test func magicPacketLayout() throws {
        let mac = try #require(MACAddress("A4:83:E7:11:22:33"))
        let packet = WakeOnLAN.magicPacket(for: mac)
        #expect(packet.count == 102)
        #expect(Array(packet.prefix(6)) == [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        // MAC이 16번 이어 붙는다
        for repetition in 0..<16 {
            let start = 6 + repetition * 6
            #expect(Array(packet[start..<(start + 6)]) == mac.bytes)
        }
        #expect(WakeOnLAN.ports == [9, 7])
    }
}
