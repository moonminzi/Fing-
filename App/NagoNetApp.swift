import SwiftData
import SwiftUI

@main
struct NagoNetApp: App {
    private let container: ModelContainer
    private let history: HistoryStore

    init() {
        container = Self.makeContainer()
        history = HistoryStore(context: container.mainContext)
        // MAC 제조사 표(1MB)는 처음 쓰기 전에 미리 읽어 둔다
        Task.detached(priority: .utility) { _ = VendorLookup.database }
    }

    var body: some Scene {
        WindowGroup {
            RootView(history: history)
        }
        .modelContainer(container)
        // 설정에서 "새 기기 알림"을 켰을 때 iOS가 가끔 깨워 준다
        .backgroundTask(.appRefresh(BackgroundCheck.taskIdentifier)) { [container = self.container] in
            await BackgroundCheck.run(container: container)
        }
    }

    /// 스캔 기록 저장소. 디스크에서 못 열면 기록 없이라도 앱이 돌게 메모리에만 둔다.
    private static func makeContainer() -> ModelContainer {
        let schema = Schema([NetworkRecord.self, DeviceRecord.self, ScanRecord.self, ScanEntry.self])
        do {
            return try ModelContainer(for: schema)
        } catch {
            print("스캔 기록 저장소를 열지 못해 메모리에만 둡니다: \(error)")
            // 메모리 저장소는 실패할 일이 없다
            return try! ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        }
    }
}
