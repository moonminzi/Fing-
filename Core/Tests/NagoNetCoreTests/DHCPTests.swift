import Testing
@testable import NagoNetCore

struct DHCPTests {
    /// BOOTP 머리(236) + 매직 쿠키 + 옵션으로 DHCP 요청 하나를 만든다.
    private func request(mac: [UInt8], requestedIP: [UInt8]?, hostName: String?, type: UInt8 = 3) -> [UInt8] {
        var packet = [UInt8](repeating: 0, count: 236)
        packet[0] = 1   // op = BOOTREQUEST(클라이언트)
        packet[1] = 1   // htype = Ethernet
        packet[2] = 6   // hlen
        for (offset, byte) in mac.enumerated() { packet[28 + offset] = byte }   // chaddr
        packet += [0x63, 0x82, 0x53, 0x63]        // 매직 쿠키
        packet += [53, 1, type]                   // option 53: 메시지 종류
        if let requestedIP { packet += [50, 4] + requestedIP }   // option 50: 요청 IP
        if let hostName {
            let bytes = Array(hostName.utf8)
            packet += [12, UInt8(bytes.count)] + bytes            // option 12: 호스트 이름
        }
        packet += [255]                           // end
        return packet
    }

    @Test func parsesRequestChaddrAndRequestedIP() {
        let mac: [UInt8] = [0xA6, 0x11, 0x22, 0x33, 0x44, 0x55]   // 무작위(로컬 관리) MAC도 유효
        let packet = request(mac: mac, requestedIP: [192, 168, 0, 42], hostName: "Minjis-iPhone")
        let sighting = DHCP.parse(packet)
        #expect(sighting?.mac == MACAddress(mac))
        #expect(sighting?.requestedIP == IPv4(192, 168, 0, 42))
        #expect(sighting?.hostName == "Minjis-iPhone")
        #expect(sighting?.messageType == 3)
    }

    @Test func parsesServerReplyChaddrViaYiaddr() {
        // 서버 응답(op=2, :68)에도 chaddr에 기기 MAC이 있고, 할당 IP는 yiaddr(offset 16)에 있다
        var reply = request(mac: [0x3C, 0x7C, 0x3F, 7, 8, 9], requestedIP: nil, hostName: nil)
        reply[0] = 2
        reply[16] = 192; reply[17] = 168; reply[18] = 0; reply[19] = 55   // yiaddr = 192.168.0.55
        #expect(DHCP.parse(reply)?.mac == MACAddress([0x3C, 0x7C, 0x3F, 7, 8, 9]))
        #expect(DHCP.parse(reply)?.requestedIP == IPv4(192, 168, 0, 55))
    }

    @Test func rejectsTooShortAndNonEthernet() {
        #expect(DHCP.parse([]) == nil)
        #expect(DHCP.parse([UInt8](repeating: 0, count: 100)) == nil)   // 너무 짧음
        var notEthernet = request(mac: [1, 2, 3, 4, 5, 6], requestedIP: nil, hostName: nil)
        notEthernet[1] = 6   // htype ≠ 1(이더넷 아님)
        #expect(DHCP.parse(notEthernet) == nil)
    }

    @Test func fallsBackToCiaddrWithoutRequestedOption() {
        var packet = request(mac: [0x3C, 0x7C, 0x3F, 1, 2, 3], requestedIP: nil, hostName: nil)
        packet[12] = 10; packet[13] = 0; packet[14] = 0; packet[15] = 9   // ciaddr = 10.0.0.9(갱신)
        #expect(DHCP.parse(packet)?.requestedIP == IPv4(10, 0, 0, 9))
    }
}
