import Foundation

/// 스캔 결과를 CSV로(엑셀·넘버스에서 한글이 깨지지 않게 BOM을 붙인다).
public enum DeviceCSV {
    public static let header = ["IP", "이름", "별명", "종류", "응답 시간(ms)", "열린 포트", "Bonjour 이름", "호스트 이름", "모델", "새 기기"]

    public static func make(_ devices: [Device], isNew: (Device) -> Bool = { _ in false }) -> String {
        var lines = [header.map(escape).joined(separator: ",")]
        for device in devices.sorted(by: .address) {
            let fields = [
                device.address.description,
                device.discoveredName ?? "",
                device.alias ?? "",
                device.kind.title,
                device.responseTime.map { String(format: "%.1f", $0.milliseconds) } ?? "",
                device.allOpenPorts.map(String.init).joined(separator: " "),
                device.bonjourName ?? "",
                device.displayHostName ?? "",
                device.model ?? "",
                isNew(device) ? "예" : "",
            ]
            lines.append(fields.map(escape).joined(separator: ","))
        }
        return "\u{FEFF}" + lines.joined(separator: "\r\n") + "\r\n"
    }

    /// 쉼표·따옴표·줄바꿈이 있으면 따옴표로 감싼다
    static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

/// 레이더 화면의 기기 자리. 공유기는 가운데, 응답이 빠를수록 안쪽 고리, 같은 종류끼리 이웃한 각도.
public struct RadarPoint: Hashable, Sendable, Identifiable {
    public let address: IPv4
    /// 12시 방향에서 시계 방향 라디안
    public let angle: Double
    /// 0(가운데)…1(가장자리)
    public let radius: Double

    public var id: IPv4 { address }
}

public enum RadarLayout {
    /// 고리 경계(응답 시간, ms): 5 미만, 20 미만, 60 미만, 그 밖(·모름)
    public static let ringLimits: [Double] = [5, 20, 60]
    static let ringRadii: [Double] = [0.34, 0.54, 0.74, 0.93]

    /// 고리 번호(0…3)
    public static func ring(for device: Device) -> Int {
        if device.isSelf { return 0 }
        guard let time = device.responseTime?.milliseconds else { return ringRadii.count - 1 }
        return ringLimits.firstIndex { time < $0 } ?? ringRadii.count - 1
    }

    public static func place(_ devices: [Device]) -> [RadarPoint] {
        var points: [RadarPoint] = []
        let gateway = devices.first { $0.isGateway }
        if let gateway {
            points.append(RadarPoint(address: gateway.address, angle: 0, radius: 0))
        }
        // 이 기기는 12시 방향, 나머지는 종류 → IP 순으로 한 바퀴에 고르게
        let me = devices.first { $0.isSelf }
        let kinds = DeviceKind.allCases
        let ranked: [(device: Device, rank: Int)] = devices
            .filter { !$0.isGateway && !$0.isSelf }
            .map { ($0, kinds.firstIndex(of: $0.kind) ?? kinds.count) }
        let others = ranked
            .sorted { lhs, rhs in lhs.rank != rhs.rank ? lhs.rank < rhs.rank : lhs.device.address < rhs.device.address }
            .map(\.device)
        let count = others.count + (me == nil ? 0 : 1)
        guard count > 0 else { return points }
        let step = 2 * Double.pi / Double(count)
        var slot = 0
        if let me {
            points.append(RadarPoint(address: me.address, angle: 0, radius: ringRadii[0]))
            slot = 1
        }
        for (index, device) in others.enumerated() {
            // 이웃끼리 겹치지 않게 고리 안에서 조금씩 안팎으로
            let wobble = index.isMultiple(of: 2) ? -0.035 : 0.035
            let radius = min(1, ringRadii[ring(for: device)] + wobble)
            points.append(RadarPoint(address: device.address, angle: Double(slot) * step, radius: radius))
            slot += 1
        }
        return points
    }

}
