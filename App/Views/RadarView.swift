import NagoNetCore
import SwiftUI

/// 네트워크 레이더: 공유기를 가운데 두고 기기를 점으로. 안쪽 고리일수록 응답이 빠르고,
/// 같은 종류끼리 이웃하며, 색·아이콘이 종류다. 스캔하는 동안 빔이 돌고, 새 기기는 깜빡인다.
struct RadarView: View {
    let devices: [Device]
    let isScanning: Bool
    let newAddresses: Set<IPv4>
    let selection: IPv4?
    let onSelect: @MainActor (IPv4) -> Void

    var body: some View {
        let points = RadarLayout.place(devices)
        let byAddress = Dictionary(uniqueKeysWithValues: devices.map { ($0.address, $0) })
        VStack(spacing: 12) {
            GeometryReader { geometry in
                let side = min(geometry.size.width, geometry.size.height)
                let radius = side / 2 - 26
                let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
                ZStack {
                    RadarRings(radius: radius)
                        .position(center)
                    if isScanning {
                        RadarSweep(radius: radius)
                            .position(center)
                    }
                    ForEach(points) { point in
                        if let device = byAddress[point.address] {
                            RadarDot(device: device, isNew: newAddresses.contains(device.address), isSelected: device.address == selection)
                                .position(position(of: point, center: center, radius: radius))
                                .onTapGesture { onSelect(device.address) }
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                }
                .animation(.spring(duration: 0.5), value: points)
            }
            .aspectRatio(1, contentMode: .fit)
            RadarLegend(devices: devices)
        }
        .padding()
    }

    private func position(of point: RadarPoint, center: CGPoint, radius: CGFloat) -> CGPoint {
        // 12시 방향에서 시계 방향
        CGPoint(x: center.x + CGFloat(sin(point.angle) * point.radius) * radius,
                y: center.y - CGFloat(cos(point.angle) * point.radius) * radius)
    }
}

/// 응답 시간 고리와 눈금 글씨.
private struct RadarRings: View {
    let radius: CGFloat
    private let labels = ["5ms", "20ms", "60ms", ""]
    private let fractions: [CGFloat] = [0.44, 0.64, 0.84, 1.0]

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Color.green.opacity(0.10), Color.green.opacity(0.02)],
                                     center: .center, startRadius: 0, endRadius: radius))
                .frame(width: radius * 2, height: radius * 2)
            ForEach(fractions.indices, id: \.self) { index in
                Circle()
                    .stroke(Color.green.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: index == 3 ? [] : [3, 4]))
                    .frame(width: radius * 2 * fractions[index], height: radius * 2 * fractions[index])
                Text(labels[index])
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .offset(x: 4, y: -radius * fractions[index] + 8)
            }
            // 가로·세로 눈금선
            Path { path in
                path.move(to: CGPoint(x: 0, y: radius))
                path.addLine(to: CGPoint(x: radius * 2, y: radius))
                path.move(to: CGPoint(x: radius, y: 0))
                path.addLine(to: CGPoint(x: radius, y: radius * 2))
            }
            .stroke(Color.green.opacity(0.12), lineWidth: 1)
            .frame(width: radius * 2, height: radius * 2)
        }
        .accessibilityHidden(true)
    }
}

/// 스캔 중에 도는 빔.
private struct RadarSweep: View {
    let radius: CGFloat

    var body: some View {
        TimelineView(.animation) { context in
            let seconds = context.date.timeIntervalSinceReferenceDate
            let angle = (seconds.truncatingRemainder(dividingBy: 3) / 3) * 360
            // 한 바퀴 그라데이션에서 마지막 60°만 밝게: 빔 뒤로 잔상이 남는다
            Circle()
                .fill(AngularGradient(
                    gradient: Gradient(stops: [
                        .init(color: Color.green.opacity(0), location: 0),
                        .init(color: Color.green.opacity(0), location: 5.0 / 6),
                        .init(color: Color.green.opacity(0.4), location: 1),
                    ]),
                    center: .center
                ))
                .frame(width: radius * 2, height: radius * 2)
                .rotationEffect(.degrees(angle - 90))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 기기 점 하나: 종류 색 원 안에 아이콘. 새 기기는 빨간 고리가 퍼지고, 고른 기기·공유기·이 기기는 이름표가 붙는다.
private struct RadarDot: View {
    let device: Device
    let isNew: Bool
    let isSelected: Bool

    var body: some View {
        let kind = device.kind
        let size: CGFloat = device.isGateway ? 40 : 26
        ZStack {
            if isNew {
                Circle()
                    .stroke(Color.red, lineWidth: 2)
                    .frame(width: size, height: size)
                    .phaseAnimator([false, true]) { ring, expanded in
                        ring.scaleEffect(expanded ? 1.9 : 1).opacity(expanded ? 0 : 0.9)
                    } animation: { _ in .easeOut(duration: 1.2) }
            }
            Circle()
                .fill(kind.tint.gradient)
                .frame(width: size, height: size)
                .shadow(color: kind.tint.opacity(0.5), radius: isSelected ? 8 : 3)
            Image(systemName: kind.symbol)
                .font(.system(size: size * 0.45, weight: .bold))
                .foregroundStyle(.white)
            if isSelected || device.isSelf {
                Circle()
                    .stroke(isSelected ? Color.primary : Color.blue, lineWidth: 2)
                    .frame(width: size + 6, height: size + 6)
            }
        }
        .overlay(alignment: .top) {
            if isSelected || device.isGateway || device.isSelf {
                Text(device.name ?? device.address.description)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.regularMaterial, in: Capsule())
                    .offset(y: size / 2 + 8)
            }
        }
        .contentShape(Circle().inset(by: -6))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(device.name ?? device.address.description), \(kind.title)\(isNew ? ", 새 기기" : "")")
        .accessibilityAddTraits(.isButton)
    }
}

/// 종류별 개수.
private struct RadarLegend: View {
    let devices: [Device]

    var body: some View {
        let counts = Dictionary(grouping: devices, by: \.kind).mapValues(\.count)
        let kinds = DeviceKind.allCases.filter { counts[$0] != nil }
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(kinds, id: \.self) { kind in
                    HStack(spacing: 5) {
                        Circle().fill(kind.tint).frame(width: 9, height: 9)
                        Text("\(kind.title) \(counts[kind] ?? 0)")
                            .font(.caption)
                            .monospacedDigit()
                    }
                }
            }
            .padding(.horizontal)
        }
    }
}

/// iPhone에서 레이더를 띄우는 화면(점을 누르면 상세로).
struct RadarScreen: View {
    let scan: ScanViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected: IPv4?

    var body: some View {
        NavigationStack {
            RadarView(devices: Array(scan.devices.values), isScanning: scan.isRunning, newAddresses: scan.newAddresses,
                      selection: selected, onSelect: { selected = $0 })
                .navigationTitle("네트워크 레이더")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("닫기") { dismiss() }
                    }
                }
                .navigationDestination(item: $selected) { address in
                    if let device = scan.devices[address] {
                        DeviceDetailView(device: device, scan: scan)
                            .id(address)
                    }
                }
        }
    }
}
