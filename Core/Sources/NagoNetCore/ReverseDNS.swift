import Dispatch
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// `getnameinfo`로 IP의 호스트 이름(PTR)을 찾는다. 보통 공유기 DNS가 DHCP로 받은 기기 이름을 알려 준다.
///
/// `getnameinfo`는 멈춰 기다리는(blocking) 함수라 Swift 동시성 스레드를 막지 않게 디스패치 큐에서 돌리고,
/// DNS가 답하지 않을 때를 대비해 시간 제한을 둔다(늦게 온 답은 버린다).
public struct ReverseDNSResolver: HostNameResolving {
    public var timeout: Duration

    public init(timeout: Duration = .seconds(3)) {
        self.timeout = timeout
    }

    public func hostName(for address: IPv4) async -> String? {
        let result = OneShot<String?>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                result.wait(with: continuation)
                DispatchQueue.global(qos: .utility).async {
                    result.resume(Self.lookup(address))
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout.milliseconds / 1_000) {
                    result.resume(nil)
                }
            }
        } onCancel: {
            result.resume(nil)
        }
    }

    /// 이름이 없으면(PTR 없음) nil.
    static func lookup(_ address: IPv4) -> String? {
        var socketAddress = sockaddr_in()
        #if canImport(Darwin)
        socketAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        socketAddress.sin_family = sa_family_t(AF_INET)
        socketAddress.sin_addr.s_addr = address.networkOrder

        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let status = withUnsafePointer(to: &socketAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size), &host, socklen_t(host.count), nil, 0, NI_NAMEREQD)
            }
        }
        guard status == 0 else { return nil }
        let name = host.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        return name.isEmpty || name == address.description ? nil : name
    }
}

/// 여러 곳(답·시간 제한·취소) 중 먼저 온 값 하나로 continuation을 딱 한 번 이어 준다.
final class OneShot<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    private var early: Value?
    private var isDone = false

    /// 기다리기 시작한다. 이미 값이 왔으면(취소가 먼저 왔으면) 바로 이어 준다.
    func wait(with continuation: CheckedContinuation<Value, Never>) {
        lock.lock()
        if isDone, let early {
            self.early = nil
            lock.unlock()
            continuation.resume(returning: early)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resume(_ value: Value) {
        lock.lock()
        guard !isDone else {
            lock.unlock()
            return
        }
        isDone = true
        guard let continuation else {
            early = value
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(returning: value)
    }
}
