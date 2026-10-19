import Foundation
import NagoNetCore
import Observation

/// 상세 화면의 핑 도구: 1초 간격으로 10번, 결과를 하나씩 보여 준다.
@MainActor @Observable
final class PingSession {
    struct Sample: Identifiable, Equatable {
        let sequence: Int
        /// 답이 없으면 nil
        let time: Duration?
        var id: Int { sequence }
    }

    static let count = 10

    private(set) var samples: [Sample] = []
    private(set) var isRunning = false
    @ObservationIgnored private var task: Task<Void, Never>?

    var statistics: PingStatistics {
        PingStatistics(samples.map(\.time))
    }

    func start(_ address: IPv4, pinger: any Pinging) {
        stop()
        samples = []
        isRunning = true
        task = Task {
            for sequence in 1...Self.count {
                let started = ContinuousClock.now
                let time = await pinger.ping(address, sequence: UInt16(sequence), timeout: .seconds(1))
                guard !Task.isCancelled else { return }
                samples.append(Sample(sequence: sequence, time: time))
                // 다음 핑까지 1초 간격(답이 늦게 왔으면 그만큼 덜 기다린다)
                let rest = Duration.seconds(1) - started.duration(to: .now)
                if rest > .zero, sequence < Self.count {
                    try? await Task.sleep(for: rest)
                }
            }
            isRunning = false
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isRunning = false
    }
}
