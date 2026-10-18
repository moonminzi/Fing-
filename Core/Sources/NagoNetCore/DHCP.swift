import Dispatch
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// DHCP 요청을 엿들어 잡은 한 건: 기기가 Wi-Fi에 붙거나 임대를 갱신할 때 자기 MAC(chaddr)을 브로드캐스트로 알린다.
///
/// 이게 "공유기 없이" 다른 기기(폰 포함) MAC을 얻는 유일하게 남은 길이다. 공유기가 아니라 **기기 자신**이
/// 브로드캐스트로 보내므로 SNMP도 관리자 비번도 필요 없다. 대신 기기가 붙거나 갱신하는 그 순간에만 잡히고(기회성),
/// MAC은 그 네트워크용 무작위 MAC이다. iOS가 그 브로드캐스트를 앱에 넘겨주는지는 기기마다 달라 실제로 측정한다.
public struct DHCPSighting: Hashable, Sendable {
    public let mac: MACAddress
    /// 요청한 IP(option 50) 또는 갱신이면 ciaddr. 아직 IP가 없으면(처음 DISCOVER) nil
    public let requestedIP: IPv4?
    public let hostName: String?
    /// DHCP 메시지 종류(option 53): 1=DISCOVER, 3=REQUEST, 8=INFORM …
    public let messageType: UInt8?

    public init(mac: MACAddress, requestedIP: IPv4?, hostName: String?, messageType: UInt8?) {
        self.mac = mac
        self.requestedIP = requestedIP
        self.hostName = hostName
        self.messageType = messageType
    }
}

/// 스니퍼가 흘리는 사건. 처음에 한 번 `.listening`(소켓을 묶음) 또는 `.blocked`(iOS가 막음)을 주고, 그 뒤 잡을 때마다 `.sighting`.
public enum DHCPEvent: Sendable {
    /// 소켓을 열고 :67에 묶었다 — iOS가 허용함
    case listening
    /// 소켓을 못 열거나 못 묶었다 — iOS가 막음(이 길은 이 기기에서 불가)
    case blocked
    case sighting(DHCPSighting)
}

/// BOOTP/DHCP 패킷을 푼다(바이트만 다루므로 플랫폼과 무관, 리눅스에서 시험된다).
public enum DHCP {
    /// 클라이언트가 보낸 요청(op=1)에서 chaddr MAC과 요청 IP·호스트 이름·메시지 종류를 꺼낸다. 요청이 아니면 nil.
    public static func parse(_ bytes: [UInt8]) -> DHCPSighting? {
        // BOOTP 머리(236) + 매직 쿠키(4)
        guard bytes.count >= 240 else { return nil }
        let op = bytes[0], htype = bytes[1], hlen = bytes[2]
        guard op == 1, htype == 1, hlen == 6 else { return nil }   // 클라이언트 요청 + 이더넷 MAC만
        guard let mac = MACAddress(Array(bytes[28..<34])) else { return nil }   // chaddr 앞 6바이트
        // 매직 쿠키(0x63825363)가 없으면 순수 BOOTP — ciaddr만 보고 끝낸다
        guard bytes[236] == 0x63, bytes[237] == 0x82, bytes[238] == 0x53, bytes[239] == 0x63 else {
            return DHCPSighting(mac: mac, requestedIP: ipv4(bytes, at: 12), hostName: nil, messageType: nil)
        }
        var messageType: UInt8?
        var requestedIP: IPv4?
        var hostName: String?
        var index = 240
        while index < bytes.count {
            let code = bytes[index]
            if code == 255 { break }        // end
            if code == 0 { index += 1; continue }   // pad
            guard index + 1 < bytes.count else { break }
            let length = Int(bytes[index + 1])
            let valueStart = index + 2
            guard valueStart + length <= bytes.count else { break }
            let value = Array(bytes[valueStart..<valueStart + length])
            switch code {
            case 53: messageType = value.first                                   // 메시지 종류
            case 50 where length == 4: requestedIP = IPv4(value[0], value[1], value[2], value[3])   // 요청 IP
            case 12: hostName = String(bytes: value, encoding: .utf8)             // 호스트 이름
            default: break
            }
            index = valueStart + length
        }
        return DHCPSighting(mac: mac, requestedIP: requestedIP ?? ipv4(bytes, at: 12),
                            hostName: hostName, messageType: messageType)
    }

    /// 4바이트 IPv4. 0.0.0.0은 "아직 없음"이라 nil.
    private static func ipv4(_ bytes: [UInt8], at offset: Int) -> IPv4? {
        guard offset + 4 <= bytes.count else { return nil }
        let ip = IPv4(bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3])
        return ip == IPv4(0, 0, 0, 0) ? nil : ip
    }
}

/// DHCP 브로드캐스트를 엿듣는 쪽. 앱은 BSD 소켓으로, 시험은 가짜로.
public protocol DHCPSniffing: Sendable {
    /// 주어진 시간 동안 :67로 오는 DHCP 요청을 엿듣는다. 소켓 상태와 잡은 것들을 스트림으로 흘린다.
    func events(on interfaceName: String?, for duration: Duration) -> AsyncStream<DHCPEvent>
}

/// `SOCK_DGRAM` UDP 소켓을 :67(DHCP 서버 포트)에 묶어, 기기들이 보내는 DISCOVER·REQUEST 브로드캐스트를 엿듣는다.
///
/// `ICMPPinger`와 같은 길: 멈춰 기다리는 소켓 읽기를 디스패치 큐에서 돌리고 200ms마다 취소를 확인한다.
/// `interfaceName`을 주면 그 인터페이스로만 듣는다(`IP_BOUND_IF`). 읽기만 하고 아무것도 보내지 않는다.
public struct DHCPSniffer: DHCPSniffing {
    public init() {}

    public func events(on interfaceName: String?, for duration: Duration) -> AsyncStream<DHCPEvent> {
        let index = interfaceName.flatMap(Interfaces.index(of:))
        return AsyncStream { continuation in
            let cancelled = CancelFlag()
            continuation.onTermination = { _ in cancelled.set() }
            DispatchQueue.global(qos: .utility).async {
                Self.listen(interfaceIndex: index, duration: duration, cancelled: cancelled) {
                    continuation.yield($0)
                }
                continuation.finish()
            }
        }
    }

    #if canImport(Darwin) || canImport(Glibc)
    private static func openSocket() -> Int32 {
        #if canImport(Glibc)
        socket(AF_INET, Int32(SOCK_DGRAM.rawValue), 0)
        #else
        socket(AF_INET, SOCK_DGRAM, 0)
        #endif
    }

    private static func listen(
        interfaceIndex: UInt32?, duration: Duration, cancelled: CancelFlag, emit: (DHCPEvent) -> Void
    ) {
        let fd = openSocket()
        guard fd >= 0 else { emit(.blocked); return }
        defer { close(fd) }

        var reuse: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var broadcast: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &broadcast, socklen_t(MemoryLayout<Int32>.size))
        #if canImport(Darwin)
        if var index = interfaceIndex {
            _ = setsockopt(fd, IPPROTO_IP, 25, &index, socklen_t(MemoryLayout<UInt32>.size))   // IP_BOUND_IF
        }
        #endif

        var addr = sockaddr_in()
        #if canImport(Darwin)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(67).bigEndian          // DHCP 서버 포트(클라이언트 요청이 여기로 온다)
        addr.sin_addr.s_addr = 0                       // INADDR_ANY
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { emit(.blocked); return }   // 못 묶으면(권한·점유) iOS가 막은 것
        emit(.listening)

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: duration)
        var buffer = [UInt8](repeating: 0, count: 2048)
        while !cancelled.isSet {
            let remaining = clock.now.duration(to: deadline)
            guard remaining > .zero else { return }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let wait = Int32(min(200, max(1, remaining.milliseconds)))
            guard poll(&descriptor, 1, wait) > 0 else { continue }
            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 0 else { continue }
            if let sighting = DHCP.parse(Array(buffer.prefix(count))) {
                emit(.sighting(sighting))
            }
        }
    }
    #else
    private static func listen(
        interfaceIndex: UInt32?, duration: Duration, cancelled: CancelFlag, emit: (DHCPEvent) -> Void
    ) {
        emit(.blocked)
    }
    #endif
}
