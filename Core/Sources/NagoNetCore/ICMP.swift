import Dispatch
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// ICMP 에코(핑) 메시지 만들기·읽기.
public enum ICMPEcho {
    static let requestType: UInt8 = 8
    static let replyType: UInt8 = 0

    /// 에코 요청: 머리 8바이트(종류·코드·체크섬·식별자·순번) + 내용
    public static func request(identifier: UInt16, sequence: UInt16, payload: [UInt8] = Array("NAGO-NET-PING-01".utf8)) -> [UInt8] {
        var packet: [UInt8] = [requestType, 0, 0, 0,
                               UInt8(identifier >> 8), UInt8(identifier & 0xFF),
                               UInt8(sequence >> 8), UInt8(sequence & 0xFF)] + payload
        let sum = checksum(packet)
        packet[2] = UInt8(sum >> 8)
        packet[3] = UInt8(sum & 0xFF)
        return packet
    }

    /// 받은 바이트가 이 순번의 에코 응답인지. 애플 커널은 IP 머리를 붙여 주고 리눅스는 떼고 주므로 둘 다 받는다.
    /// 리눅스는 식별자를 소켓 번호로 바꿔 보내서 식별자는 보지 않는다(소켓 하나에 질문 하나라 순번으로 충분하다).
    public static func isReply(_ bytes: [UInt8], sequence: UInt16) -> Bool {
        var start = 0
        if let first = bytes.first, first >> 4 == 4 {
            start = Int(first & 0x0F) * 4
        }
        guard bytes.count >= start + 8 else { return false }
        let icmp = Array(bytes[start...])
        return icmp[0] == replyType && icmp[1] == 0 && (UInt16(icmp[6]) << 8 | UInt16(icmp[7])) == sequence
    }

    /// 인터넷 체크섬(16비트 1의 보수 합)
    static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var index = 0
        while index + 1 < bytes.count {
            sum += UInt32(bytes[index]) << 8 | UInt32(bytes[index + 1])
            index += 2
        }
        if index < bytes.count {
            sum += UInt32(bytes[index]) << 8
        }
        while sum >> 16 != 0 {
            sum = (sum & 0xFFFF) + (sum >> 16)
        }
        return ~UInt16(sum)
    }
}

/// 핑 한 번. 답이 없으면 nil.
public protocol Pinging: Sendable {
    func ping(_ address: IPv4, sequence: UInt16, timeout: Duration) async -> Duration?
}

/// `SOCK_DGRAM` ICMP 소켓으로 핑한다(raw 소켓이 아니라서 iOS 앱도 쓸 수 있다, Apple SimplePing과 같은 방식).
///
/// `interfaceName`을 주면 그 인터페이스로만 나간다(`IP_BOUND_IF`, VPN이 켜져 있어도 Wi-Fi로).
/// 소켓 읽기는 멈춰 기다리는 함수라 디스패치 큐에서 돌리고, 100ms마다 취소를 확인한다.
public struct ICMPPinger: Pinging {
    public var interfaceName: String?

    public init(interfaceName: String? = nil) {
        self.interfaceName = interfaceName
    }

    /// 이 기계에서 ICMP 데이터그램 소켓을 열 수 있는지(리눅스는 ping_group_range 설정에 따라 막혀 있다)
    public static var isAvailable: Bool {
        let fd = openSocket()
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }

    public func ping(_ address: IPv4, sequence: UInt16, timeout: Duration) async -> Duration? {
        let cancelled = CancelFlag()
        let index = interfaceName.flatMap(Interfaces.index(of:))
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: Self.blockingPing(
                        address, sequence: sequence, timeout: timeout, interfaceIndex: index, cancelled: cancelled
                    ))
                }
            }
        } onCancel: {
            cancelled.set()
        }
    }

    private static func openSocket() -> Int32 {
        #if canImport(Glibc)
        socket(AF_INET, Int32(SOCK_DGRAM.rawValue), Int32(IPPROTO_ICMP))
        #else
        socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        #endif
    }

    private static func blockingPing(
        _ address: IPv4, sequence: UInt16, timeout: Duration, interfaceIndex: UInt32?, cancelled: CancelFlag
    ) -> Duration? {
        let fd = openSocket()
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        #if canImport(Darwin)
        if var index = interfaceIndex {
            // IP_BOUND_IF(25): 이 인터페이스로만 보낸다
            _ = setsockopt(fd, IPPROTO_IP, 25, &index, socklen_t(MemoryLayout<UInt32>.size))
        }
        #endif

        var target = sockaddr_in()
        #if canImport(Darwin)
        target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        target.sin_family = sa_family_t(AF_INET)
        target.sin_addr.s_addr = address.networkOrder

        let packet = ICMPEcho.request(identifier: UInt16.random(in: 1...UInt16.max), sequence: sequence)
        let clock = ContinuousClock()
        let sentAt = clock.now
        let sent = withUnsafePointer(to: &target) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard sent == packet.count else { return nil }

        let deadline = sentAt.advanced(by: timeout)
        var buffer = [UInt8](repeating: 0, count: 1500)
        while !cancelled.isSet {
            let remaining = clock.now.duration(to: deadline)
            guard remaining > .zero else { return nil }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let wait = Int32(min(100, max(1, remaining.milliseconds)))
            guard poll(&descriptor, 1, wait) > 0 else { continue }

            var source = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &source) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, &buffer, buffer.count, 0, $0, &length)
                }
            }
            guard count > 0 else { continue }
            if IPv4(networkOrder: source.sin_addr.s_addr) == address,
               ICMPEcho.isReply(Array(buffer.prefix(count)), sequence: sequence) {
                return sentAt.duration(to: clock.now)
            }
        }
        return nil
    }
}

/// 여러 스레드에서 보는 "그만" 표시.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }

    func set() {
        lock.withLock { value = true }
    }
}

/// 핑 여러 번의 결과 요약.
public struct PingStatistics: Hashable, Sendable {
    public let sent: Int
    public let received: Int
    public let minimum: Duration?
    public let average: Duration?
    public let maximum: Duration?
    /// 응답 시간의 흔들림(연속한 두 응답 차이의 평균)
    public let jitter: Duration?

    public init(_ samples: [Duration?]) {
        let times = samples.compactMap { $0 }
        sent = samples.count
        received = times.count
        minimum = times.min()
        maximum = times.max()
        average = times.isEmpty ? nil : times.reduce(.zero, +) / times.count
        if times.count >= 2 {
            let gaps = zip(times, times.dropFirst()).map { abs(($0 - $1).milliseconds) }
            jitter = .microseconds(Int64(gaps.reduce(0, +) / Double(gaps.count) * 1_000))
        } else {
            jitter = nil
        }
    }

    /// 0…1
    public var lossRate: Double {
        sent == 0 ? 0 : Double(sent - received) / Double(sent)
    }
}
