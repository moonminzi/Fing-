import SwiftUI

/// iPad는 왼쪽 목록·오른쪽 상세 두 칸, iPhone은 접혀서 한 칸씩 쌓인다.
struct RootView: View {
    @State private var network = NetworkViewModel()
    @State private var location = LocationPermission()

    var body: some View {
        NavigationSplitView {
            HomeView(network: network, location: location)
                .navigationSplitViewColumnWidth(min: 320, ideal: 380)
        } detail: {
            ContentUnavailableView(
                "기기를 골라 주세요",
                systemImage: "laptopcomputer.and.iphone",
                description: Text("스캔한 뒤 목록에서 기기를 누르면 자세한 정보가 여기 나와요.")
            )
        }
    }
}
