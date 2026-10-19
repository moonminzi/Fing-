import Foundation
import Testing
@testable import NagoNetCore

struct NDPSpoofTests {
    // fe80::1 (게이트웨이)·fe80::2 (피해자)
    static let gatewayIP = IPv6Address([0xFE, 0x80] + [UInt8](repeating: 0, count: 13) + [1])!
    static let victimIP = IPv6Address([0xFE, 0x80] + [UInt8](repeating: 0, count: 13) + [2])!
    static let attackerMAC = MACAddress([0xAA, 0xBB, 0xCC, 0x11, 0x22, 0x33])!
    static let realGatewayMAC = MACAddress([0x3C, 0x7C, 0x3F, 0x44, 0x55, 0x66])!

    @Test func buildsNeighborAdvertisementBytes() {
        let na = NDPSpoof.advertisement(target: Self.gatewayIP, linkLayer: Self.attackerMAC, flags: [.overrideExisting, .router])
        #expect(na.count == 32)
        #expect(Array(na[0..<4]) == [136, 0, 0, 0])            // type 136, code 0, checksum 0(커널이 채움)
        #expect(na[4] == 0xA0)                                  // flags: Router(0x80) | Override(0x20)
        #expect(Array(na[5..<8]) == [0, 0, 0])                  // 예약
        #expect(Array(na[8..<24]) == Self.gatewayIP.bytes)      // 사칭할 IPv6
        #expect(Array(na[24..<26]) == [2, 1])                   // TLLA 옵션: 종류 2, 길이 1칸
        #expect(Array(na[26..<32]) == Self.attackerMAC.bytes)   // 속일 MAC

        // 그대로 읽어 들이면 우리가 넣은 MAC이 나와야 한다(NeighborDiscovery가 NA를 파싱하는 그 길)
        #expect(NeighborDiscovery.mac(in: na) == Self.attackerMAC)
    }

    @Test func overrideOnlyClearsRouterBit() {
        let na = NDPSpoof.advertisement(target: Self.victimIP, linkLayer: Self.attackerMAC, flags: .overrideExisting)
        #expect(na[4] == 0x20)   // Override만, Router·Solicited 꺼짐
    }

    @Test func mitmMakesTwoCrossedPoisonMoves() {
        let moves = NDPSpoof.mitm(victim: Self.victimIP, gateway: Self.gatewayIP, attackerMAC: Self.attackerMAC)
        #expect(moves.count == 2)

        // 피해자에게: "게이트웨이는 내 MAC"(라우터 사칭)
        let toVictim = moves[0]
        #expect(toVictim.destination == Self.victimIP)
        #expect(toVictim.impersonatedIP == Self.gatewayIP)
        #expect(toVictim.posingAsRouter)
        #expect(toVictim.poisonPayload[4] == 0xA0)                       // Override | Router
        #expect(Array(toVictim.poisonPayload[8..<24]) == Self.gatewayIP.bytes)
        #expect(Array(toVictim.poisonPayload[26..<32]) == Self.attackerMAC.bytes)

        // 게이트웨이에게: "피해자는 내 MAC"(호스트 사칭이라 Router 끔)
        let toGateway = moves[1]
        #expect(toGateway.destination == Self.gatewayIP)
        #expect(toGateway.impersonatedIP == Self.victimIP)
        #expect(!toGateway.posingAsRouter)
        #expect(toGateway.poisonPayload[4] == 0x20)                      // Override만
        #expect(Array(toGateway.poisonPayload[8..<24]) == Self.victimIP.bytes)
    }

    @Test func restorePayloadCarriesRealMAC() {
        let move = NDPSpoof.mitm(victim: Self.victimIP, gateway: Self.gatewayIP, attackerMAC: Self.attackerMAC)[0]
        let restore = move.restorePayload(realMAC: Self.realGatewayMAC)
        #expect(Array(restore[8..<24]) == Self.gatewayIP.bytes)         // 여전히 게이트웨이 주소에 대해
        #expect(Array(restore[26..<32]) == Self.realGatewayMAC.bytes)   // 이번엔 진짜 MAC으로 되돌림
        #expect(restore[4] & 0x20 != 0)                                 // Override로 다시 덮음
    }

    @Test func poisonResendsEachRoundAndRecordsSends() async {
        let fake = RecordingAdvertiser(succeed: true)
        let moves = NDPSpoof.mitm(victim: Self.victimIP, gateway: Self.gatewayIP, attackerMAC: Self.attackerMAC)
        let run = await NDPSpoofer(advertiser: fake).poison(moves, on: "en0", every: .seconds(1), for: .zero)
        #expect(run.rounds == 1)        // 기간 0이라도 한 바퀴는 돈다
        #expect(run.sent == 2)          // 피해자·게이트웨이 양쪽
        #expect(!run.blocked)
        #expect(fake.calls.count == 2)
        #expect(fake.calls.map(\.destination) == [Self.victimIP, Self.gatewayIP])
    }

    @Test func poisonReportsBlockedWhenNothingLeaves() async {
        let fake = RecordingAdvertiser(succeed: false)   // iOS가 막은 척
        let moves = NDPSpoof.mitm(victim: Self.victimIP, gateway: Self.gatewayIP, attackerMAC: Self.attackerMAC)
        let run = await NDPSpoofer(advertiser: fake).poison(moves, on: nil, every: .seconds(1), for: .zero)
        #expect(run.sent == 0)
        #expect(run.blocked)
    }

    @Test func restoreSendsRealMACToEachTargetTimesOver() {
        let fake = RecordingAdvertiser(succeed: true)
        let moves = NDPSpoof.mitm(victim: Self.victimIP, gateway: Self.gatewayIP, attackerMAC: Self.attackerMAC)
        let realMACs = [Self.gatewayIP: Self.realGatewayMAC]   // 피해자 쪽(게이트웨이 사칭)만 진짜 MAC을 안다
        let sent = NDPSpoofer(advertiser: fake).restore(moves, realMACs: realMACs, on: "en0", times: 2)
        #expect(sent == 2)   // 2바퀴 × 진짜 MAC을 아는 1개 수
        #expect(fake.calls.allSatisfy { $0.destination == Self.victimIP })
        #expect(fake.calls.allSatisfy { Array($0.payload[26..<32]) == Self.realGatewayMAC.bytes })
    }
}

/// 보낸 NA를 적어 두는 가짜 Advertiser(진짜 소켓 없이 조율자 로직만 시험).
private final class RecordingAdvertiser: NeighborAdvertising, @unchecked Sendable {
    struct Call { let payload: [UInt8]; let destination: IPv6Address; let interface: String? }

    private let succeed: Bool
    private let lock = NSLock()
    private var recorded: [Call] = []

    init(succeed: Bool) { self.succeed = succeed }

    var calls: [Call] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func advertise(_ payload: [UInt8], to destination: IPv6Address, on interfaceName: String?) -> Bool {
        lock.lock()
        recorded.append(Call(payload: payload, destination: destination, interface: interfaceName))
        lock.unlock()
        return succeed
    }
}
