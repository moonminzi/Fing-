import NagoNetCore
import SwiftUI
import UIKit

/// 네트워크 이름·내 IP·게이트웨이·서브넷·스캔 범위를 보여 주는 카드.
struct NetworkCard: View {
    let snapshot: NetworkSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "wifi")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.tint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.ssid ?? "이름 모를 Wi-Fi")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(snapshot.ssid == nil ? .secondary : .primary)
                        .lineLimit(1)
                    Text("Wi-Fi · \(snapshot.interfaceName) · \(snapshot.subnet.cidr)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    label("내 IP")
                    Text(snapshot.myAddress.description)
                }
                GridRow {
                    label("게이트웨이")
                    HStack(spacing: 6) {
                        Text(snapshot.gateway.address.description)
                        if snapshot.gateway.isEstimated {
                            TagBadge(text: "추정", tint: .orange)
                        }
                    }
                }
                GridRow {
                    label("서브넷")
                    Text("\(snapshot.subnet.mask.description) (/\(snapshot.subnet.prefixLength))")
                }
                if let bssid = snapshot.bssid {
                    GridRow {
                        label("접속 AP")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(bssid.description)
                            if let vendor = VendorLookup.vendor(for: bssid) {
                                Text(vendor)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                GridRow {
                    label("스캔 범위")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(snapshot.scanRange.addresses.lowerBound.description) – \(snapshot.scanRange.addresses.upperBound.description)")
                        Text("\(snapshot.scanRange.count.formatted())개 주소")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .font(.subheadline)
            .monospacedDigit()
            .textSelection(.enabled)
        }
        .padding(.vertical, 6)
    }

    private func label(_ title: String) -> some View {
        Text(title)
            .foregroundStyle(.secondary)
    }
}

/// "추정", "새 기기" 같은 작은 꼬리표.
struct TagBadge: View {
    let text: String
    var tint: Color = .accentColor

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(tint)
            .background(tint.opacity(0.15), in: Capsule())
    }
}

/// SSID를 못 읽을 때 이유와 할 일(위치 권한 요청·설정 열기)을 보여 준다. 읽었으면 아무것도 안 그린다.
struct WiFiNameAccessRow: View {
    let location: LocationPermission
    let hasName: Bool

    @Environment(\.openURL) private var openURL

    var body: some View {
        if !hasName {
            switch location.state {
            case .notDetermined:
                action("네트워크 이름 보기", systemImage: "location",
                       note: "iOS는 Wi-Fi 이름을 알려 줄 때 정확한 위치 권한을 요구해요. 위치는 쓰거나 저장하지 않아요.") {
                    location.request()
                }
            case .approximate:
                action("정확한 위치 허용", systemImage: "location.circle",
                       note: "대략적인 위치만 허용되어 있어 Wi-Fi 이름을 읽을 수 없어요.") {
                    location.request()
                }
            case .denied:
                action("설정에서 위치 허용", systemImage: "gear",
                       note: "위치 권한이 꺼져 있어 Wi-Fi 이름을 읽을 수 없어요. 나머지 기능은 그대로 쓸 수 있어요.") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            case .precise:
                Label {
                    Text("Wi-Fi 이름을 읽지 못했어요. 앱 서명에 Access Wi-Fi Information 권한이 들어 있는지 확인하세요.")
                } icon: {
                    Image(systemName: "info.circle")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func action(_ title: String, systemImage: String, note: String, perform: @escaping @MainActor () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                perform()
            } label: {
                Label(title, systemImage: systemImage)
            }
            Text(note)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
