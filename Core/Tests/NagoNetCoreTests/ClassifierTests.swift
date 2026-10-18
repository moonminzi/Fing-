import Testing
@testable import NagoNetCore

private let ip = IPv4(192, 168, 10, 50)

private func device(ports: [UInt16] = [], names: (bonjour: String?, host: String?) = (nil, nil),
                    services: [BonjourService] = [], model: String? = nil,
                    banners: [ServiceBanner] = [], netbios: String? = nil, gateway: Bool = false) -> Device {
    var device = Device(address: ip, responseTime: .milliseconds(5), openPorts: ports, isGateway: gateway)
    if let bonjour = names.bonjour {
        device.merge(BonjourService(name: bonjour, type: "_companion-link._tcp", address: ip))
    }
    services.forEach { device.merge($0) }
    device.mdnsName = names.host
    device.deviceInfoModel = model
    banners.forEach { device.merge($0) }
    device.netbiosName = netbios
    return device
}

struct ClassifierTests {
    @Test func appleDevicesByNameAndModel() {
        #expect(device(ports: [62078], names: ("민지의 iPad", nil)).kind == .tablet)
        #expect(device(ports: [62078], names: ("김윤성의 iPhone", nil)).kind == .iPhone)
        // 이름("동혁pad")만으로는 모르지만 모델 식별자가 있으면 정확히
        #expect(device(ports: [62078], names: ("동혁pad", nil), model: "iPad7,5").kind == .tablet)
        #expect(device(names: ("거실", nil), model: "AppleTV14,1").kind == .tv)
        #expect(device(names: ("주방", nil), model: "AudioAccessory5,1").kind == .speaker)
        #expect(device(names: (nil, "Minjis-MacBook-Pro.local"), model: "Mac15,6").kind == .mac)
        // 이름 없는 62078 기기는 iPhone으로
        #expect(device(ports: [62078]).kind == .iPhone)
    }

    @Test func reasonsComeWithTheKind() {
        let classification = device(ports: [62078], names: ("동혁pad", nil), model: "iPad7,5").classification
        #expect(classification.kind == .tablet)
        #expect(classification.reasons.first == "모델 iPad7,5")
        #expect(classification.reasons.contains("iPhone·iPad 동기화 포트(62078)"))
    }

    @Test func infrastructureFromBanners() {
        let unifi = ServiceBanner(port: 443, certificate: "UniFi")
        #expect(device(ports: [22, 80, 443], banners: [unifi]).kind == .router)
        let iptime = ServiceBanner(port: 80, title: "ipTIME A3004NS-M")
        #expect(device(ports: [80], banners: [iptime]).kind == .router)
        let printer = ServiceBanner(port: 80, server: "HP HTTP Server; HP LaserJet Pro M404dn")
        #expect(device(ports: [80, 9100], banners: [printer]).kind == .printer)
        let nas = ServiceBanner(port: 5001, title: "Synology DiskStation")
        #expect(device(ports: [5000, 5001], banners: [nas]).kind == .nas)
        let linux = ServiceBanner(port: 22, ssh: "OpenSSH_9.6p1 Ubuntu-3ubuntu13")
        #expect(device(ports: [22], banners: [linux]).kind == .computer)
        let embedded = ServiceBanner(port: 22, ssh: "dropbear_2020.81")
        #expect(device(ports: [22, 80], banners: [embedded]).kind == .router)
    }

    @Test func servicesPortsAndNetBIOS() {
        let cast = BonjourService(name: "Chromecast-1", type: "_googlecast._tcp", address: ip, txt: ["md": "Chromecast", "fn": "안방 TV"])
        #expect(device(services: [cast]).kind == .tv)
        let nest = BonjourService(name: "Nest-1", type: "_googlecast._tcp", address: ip, txt: ["md": "Google Nest Mini"])
        #expect(device(services: [nest]).kind == .speaker)
        let ipp = BonjourService(name: "Brother HL-L2350DW", type: "_ipp._tcp", address: ip)
        #expect(device(services: [ipp]).kind == .printer)
        #expect(device(ports: [631, 9100]).kind == .printer)
        #expect(device(ports: [135, 139, 445, 3389]).kind == .computer)
        #expect(device(netbios: "MINJI-PC").kind == .computer)
        #expect(device(ports: [8009, 8008]).kind == .tv)
        #expect(device(names: (nil, "Galaxy-S23.local")).kind == .phone)
        #expect(device(names: (nil, "Galaxy-Tab-S9.local")).kind == .tablet)
        #expect(device(names: (nil, "galaxy-book3.local")).kind == .computer)
    }

    @Test func gatewayWinsAndSilentDevicesAreUnknown() {
        #expect(device(ports: [80], gateway: true).kind == .router)
        #expect(device().kind == .unknown)
        #expect(device().classification.reasons.isEmpty)
        // 웹 포트 하나만으로는 모른다
        #expect(device(ports: [80, 443]).kind == .unknown)
    }

    @Test func nameMatchingUsesWholeWordsForShortKeywords() {
        #expect(DeviceClassifier.kind(forName: "Living Room TV")?.0 == .tv)
        #expect(DeviceClassifier.kind(forName: "Stvnet")?.0 == nil)   // "tv"가 단어가 아님
        #expect(DeviceClassifier.kind(forName: "MINJI-PC")?.0 == .computer)
        #expect(DeviceClassifier.kind(forName: "epcot") == nil)
        #expect(DeviceClassifier.kind(forName: "거실 스피커")?.0 == .speaker)
    }
}

struct DeviceAliasAndSortTests {
    @Test func aliasWinsOverDiscoveredNames() {
        var tablet = device(ports: [62078], names: ("민지의 iPad", nil))
        tablet.alias = "교탁 아이패드"
        #expect(tablet.name == "교탁 아이패드")
        #expect(tablet.discoveredName == "민지의 iPad")
    }

    @Test func productNameFromBannersBeforeGatewayFallback() {
        var router = device(ports: [80], gateway: true)
        #expect(router.name == "공유기")
        router.merge(ServiceBanner(port: 80, title: "Login"))
        #expect(router.name == "공유기")
        router.merge(ServiceBanner(port: 80, realm: "ipTIME A3004NS"))
        #expect(router.name == "ipTIME A3004NS")
    }

    @Test func vendorNameFromBanners() {
        // 실기기에서 본 Aruba AP: 제목은 "302"(리디렉션), 인증서가 Aruba 로그인 포털
        let redirect = "HTTP/1.1 302 Found\r\nLocation: https://securelogin.arubanetworks.com/cgi-bin/login\r\n\r\n<title>302</title>"
        let http = ServiceBanner.http(port: 80, response: Array(redirect.utf8))
        #expect(http?.title == nil)
        #expect(http?.redirect == "https://securelogin.arubanetworks.com/cgi-bin/login")
        #expect(http?.vendor == "Aruba")
        let https = ServiceBanner.http(port: 443, response: Array("HTTP/1.1 302 Found\r\n\r\n".utf8),
                                       certificate: "securelogin.arubanetworks.com")
        let ap = device(ports: [22, 80, 443], banners: [http, https].compactMap { $0 })
        #expect(ap.kind == .router)
        #expect(ap.name == "Aruba AP")
        #expect(device(ports: [80], banners: [ServiceBanner(port: 80, title: "Synology DiskStation")]).name == "Synology DiskStation")
        #expect(device(ports: [80, 9100], banners: [ServiceBanner(port: 80, server: "HP HTTP Server")]).name == "HP 프린터")
    }

    @Test func identityKeysPreferNamesOverIP() {
        let named = device(names: ("민지의 iPad", "Minji-iPad.local"))
        #expect(named.identity.keys(network: "192.168.10.0/23") == [
            "bonjour:민지의 ipad", "host:minji-ipad", "ip:192.168.10.0/23/192.168.10.50",
        ])
        #expect(device().identity.keys(network: "net") == ["ip:net/192.168.10.50"])
    }

    @Test func sortsByKindThenName() {
        var router = Device(address: IPv4(192, 168, 10, 1), responseTime: .milliseconds(1), isGateway: true)
        router.openPorts = [80]
        let pad = device(ports: [62078], names: ("가나 iPad", nil))
        var phone = Device(address: IPv4(192, 168, 10, 9), responseTime: .milliseconds(1), openPorts: [62078])
        phone.merge(BonjourService(name: "다라의 iPhone", type: "_companion-link._tcp", address: phone.address))
        let unknown = Device(address: IPv4(192, 168, 10, 2), responseTime: .milliseconds(1))
        let sorted = [unknown, pad, phone, router].sorted(by: .kind).map(\.kind)
        #expect(sorted == [.router, .iPhone, .tablet, .unknown])
    }
}

struct BannerTests {
    @Test func parsesHTTPHeadersTitleAndRealm() {
        let response = """
        HTTP/1.1 401 Unauthorized\r
        Server: lighttpd/1.4.59\r
        WWW-Authenticate: Basic realm="TP-LINK Wireless N Router WR841N"\r
        Content-Type: text/html\r
        \r
        <html><head><TITLE>  Archer &amp; Co\n  Router </TITLE></head></html>
        """
        let banner = ServiceBanner.http(port: 80, response: Array(response.utf8))
        #expect(banner?.server == "lighttpd/1.4.59")
        #expect(banner?.realm == "TP-LINK Wireless N Router WR841N")
        #expect(banner?.title == "Archer & Co Router")
        #expect(banner?.productName == "TP-LINK Wireless N Router WR841N")
    }

    @Test func genericTitlesAreNotNames() {
        for title in ["Login", "404 Not Found", "Welcome to nginx!", "Index of /", "192.168.0.1", "로그인", "Redirecting..."] {
            let response = "HTTP/1.0 200 OK\r\n\r\n<title>\(title)</title>"
            #expect(ServiceBanner.http(port: 80, response: Array(response.utf8))?.productName == nil, "\(title)")
        }
        let good = "HTTP/1.0 200 OK\r\n\r\n<title>RICOH MP C3004</title>"
        #expect(ServiceBanner.http(port: 80, response: Array(good.utf8))?.productName == "RICOH MP C3004")
    }

    @Test func httpsCertificateNameAndNonHTTP() {
        let banner = ServiceBanner.http(port: 443, response: Array("HTTP/1.1 200 OK\r\n\r\n".utf8), certificate: "UniFi")
        #expect(banner?.productName == "UniFi")
        #expect(ServiceBanner.http(port: 443, response: [], certificate: "192.168.10.11")?.productName == nil)
        #expect(ServiceBanner.http(port: 80, response: Array("garbage".utf8)) == nil)
    }

    @Test func parsesSSHGreeting() {
        let banner = ServiceBanner.ssh(port: 22, greeting: Array("SSH-2.0-OpenSSH_8.4p1 Debian-5+deb11u3\r\n".utf8))
        #expect(banner?.ssh == "OpenSSH_8.4p1 Debian-5+deb11u3")
        #expect(ServiceBanner.ssh(port: 22, greeting: Array("hello\r\n".utf8)) == nil)
    }

    @Test func picksPortsWorthReading() {
        #expect(BannerPorts.worthReading(among: [22, 80, 443, 8080, 62078]) == [80, 443, 22])
        #expect(BannerPorts.worthReading(among: [62078, 7000]).isEmpty)
    }

    @Test func knownPortsHasExactly100() {
        #expect(KnownPorts.common.count == 100)
        #expect(Set(KnownPorts.commonPorts).count == 100)
        #expect(Set(ScanConfiguration.discoveryPorts).isSubset(of: Set(KnownPorts.commonPorts)))
        #expect(KnownPorts.name(for: 62078) == "iPhone 동기화(lockdown)")
    }
}

private struct ScriptedProber: HostProbing {
    let open: Set<UInt16>
    let log = PortLog()
    func probe(_ host: IPv4, port: UInt16, timeout: Duration) async -> PortProbeResult {
        await log.enter()
        try? await Task.sleep(for: .milliseconds(2))
        await log.leave()
        return open.contains(port) ? .open(.milliseconds(1)) : .refused(.milliseconds(1))
    }
}

private actor PortLog {
    var inFlight = 0, peak = 0, calls = 0
    func enter() { inFlight += 1; calls += 1; peak = max(peak, inFlight) }
    func leave() { inFlight -= 1 }
}

struct PortScannerTests {
    @Test func findsOpenPortsWithinLimit() async {
        let prober = ScriptedProber(open: [22, 443, 9100])
        let scanner = PortScanner(prober: prober, maxConcurrentConnections: 10)
        var open: [UInt16] = []
        var last: PortScanEvent?
        for await event in scanner.scan(ip, ports: KnownPorts.commonPorts) {
            if case .open(let port) = event { open.append(port) }
            last = event
        }
        #expect(open.sorted() == [22, 443, 9100])
        #expect(last == .progress(completed: 100, total: 100))
        #expect(await prober.log.peak <= 10)
        #expect(await prober.log.calls == 100)
    }
}
