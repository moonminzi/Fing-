import Testing
@testable import NagoNetCore

struct SubnetTests {
    private func subnet(_ address: String, _ mask: String) throws -> Subnet {
        let address = try #require(IPv4(address))
        let mask = try #require(IPv4(mask))
        return try #require(Subnet(address: address, mask: mask))
    }

    @Test func homeNetwork() throws {
        let net = try subnet("192.168.0.23", "255.255.255.0")
        #expect(net.prefixLength == 24)
        #expect(net.network == IPv4(192, 168, 0, 0))
        #expect(net.broadcast == IPv4(192, 168, 0, 255))
        #expect(net.cidr == "192.168.0.0/24")
        #expect(net.hosts == IPv4(192, 168, 0, 1)...IPv4(192, 168, 0, 254))
        #expect(net.hostCount == 254)
        #expect(net.conventionalGateway == IPv4(192, 168, 0, 1))
        #expect(net.contains(IPv4(192, 168, 0, 200)))
        #expect(!net.contains(IPv4(192, 168, 1, 1)))

        let range = net.scanRange(limit: 1024)
        #expect(range.addresses == net.hosts)
        #expect(!range.isPartial)
    }

    @Test func prefixLengthInit() throws {
        let net = try #require(Subnet(address: IPv4(10, 1, 2, 3), prefixLength: 20))
        #expect(net.mask == IPv4(255, 255, 240, 0))
        #expect(Subnet(address: IPv4(10, 1, 2, 3), prefixLength: 0)?.mask == IPv4(0))
        #expect(Subnet(address: IPv4(10, 1, 2, 3), prefixLength: 32)?.mask == IPv4(0xFFFF_FFFF))
        #expect(Subnet(address: IPv4(10, 1, 2, 3), prefixLength: 33) == nil)
    }

    @Test(arguments: ["255.0.255.0", "255.255.255.1", "0.255.255.255"])
    func rejectsNonContiguousMask(_ mask: String) throws {
        #expect(Subnet(address: IPv4(10, 0, 0, 1), mask: try #require(IPv4(mask))) == nil)
    }

    @Test func tinyNetworks() throws {
        let p30 = try subnet("10.0.0.1", "255.255.255.252")
        #expect(p30.hosts == IPv4(10, 0, 0, 1)...IPv4(10, 0, 0, 2))

        // /31은 네트워크·브로드캐스트 주소가 없다(RFC 3021)
        let p31 = try subnet("10.0.0.1", "255.255.255.254")
        #expect(p31.hosts == IPv4(10, 0, 0, 0)...IPv4(10, 0, 0, 1))

        let p32 = try subnet("10.0.0.9", "255.255.255.255")
        #expect(p32.hosts == IPv4(10, 0, 0, 9)...IPv4(10, 0, 0, 9))
        #expect(p32.hostCount == 1)
    }

    @Test func networksUpToLimitAreScannedWhole() throws {
        // /22는 1022개라서 다 스캔
        let net = try subnet("172.16.5.10", "255.255.252.0")
        let range = net.scanRange(limit: 1024)
        #expect(range.addresses == IPv4(172, 16, 4, 1)...IPv4(172, 16, 7, 254))
        #expect(range.count == 1022)
        #expect(!range.isPartial)
    }

    @Test func largeNetworkScansBlockAroundMe() throws {
        // /16에서 10.0.5.23이면 그 주소가 든 /22 칸(10.0.4.0–10.0.7.255)
        let net = try subnet("10.0.5.23", "255.255.0.0")
        #expect(net.hostCount == 65534)
        let range = net.scanRange(limit: 1024)
        #expect(range.isPartial)
        #expect(range.addresses == IPv4(10, 0, 4, 0)...IPv4(10, 0, 7, 255))
        #expect(range.count == 1024)
        #expect(range.addresses.contains(net.address))
    }

    @Test func largeNetworkBlockSkipsNetworkAndBroadcast() throws {
        // 내 주소가 대역의 맨 앞 칸이면 네트워크 주소(10.0.0.0)는 뺀다
        let low = try subnet("10.0.1.1", "255.255.0.0").scanRange(limit: 1024)
        #expect(low.addresses == IPv4(10, 0, 0, 1)...IPv4(10, 0, 3, 255))
        #expect(low.count == 1023)

        let high = try subnet("10.0.254.1", "255.255.0.0").scanRange(limit: 1024)
        #expect(high.addresses == IPv4(10, 0, 252, 0)...IPv4(10, 0, 255, 254))
    }

    @Test func nonPowerOfTwoLimitRoundsDown() throws {
        let range = try subnet("10.0.5.23", "255.255.0.0").scanRange(limit: 1000)
        #expect(range.count == 512)
        #expect(range.addresses == IPv4(10, 0, 4, 0)...IPv4(10, 0, 5, 255))
    }
}
