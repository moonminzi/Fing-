import NagoNetCore
import SwiftUI

/// iPad는 왼쪽 목록·오른쪽 상세 두 칸, iPhone은 접혀서 한 칸씩 쌓인다.
struct RootView: View {
    @State private var network = NetworkViewModel()
    @State private var scan: ScanViewModel
    @State private var location = LocationPermission()
    @State private var selection: IPv4?

    init(history: any ScanHistoryStoring) {
        _scan = State(initialValue: ScanViewModel(history: history))
    }

    var body: some View {
        NavigationSplitView {
            HomeView(network: network, scan: scan, location: location, selection: $selection)
                .navigationSplitViewColumnWidth(min: 320, ideal: 380)
        } detail: {
            if let selection, let device = scan.devices[selection] {
                DeviceDetailView(device: device, scan: scan, onShowRadar: { self.selection = nil })
                    .id(selection)
            } else if !scan.devices.isEmpty {
                // iPad: 고른 기기가 없으면 오른쪽 칸 전체가 레이더
                RadarView(devices: Array(scan.devices.values), isScanning: scan.isRunning,
                          newAddresses: scan.newAddresses, selection: nil, onSelect: { selection = $0 })
                    .navigationTitle("네트워크 레이더")
                    .navigationBarTitleDisplayMode(.inline)
            } else {
                ContentUnavailableView(
                    "기기를 골라 주세요",
                    systemImage: "laptopcomputer.and.iphone",
                    description: Text("스캔하면 여기에 네트워크 레이더가 나오고, 기기를 누르면 자세한 정보가 나와요.")
                )
            }
        }
    }
}
