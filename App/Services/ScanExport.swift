import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// 공유 시트로 보내는 CSV 파일("NAGO-NET-GreenLamp49-2026-10-18-1930.csv").
struct ScanExport: Transferable, Sendable {
    let csv: String
    let networkName: String
    let date: Date

    var fileName: String {
        let safe = String(networkName.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" })
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let stamp = String(format: "%04d-%02d-%02d-%02d%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
                           parts.hour ?? 0, parts.minute ?? 0)
        return "NAGO-NET-\(safe)-\(stamp).csv"
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .commaSeparatedText) { export in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(export.fileName)
            try Data(export.csv.utf8).write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}
