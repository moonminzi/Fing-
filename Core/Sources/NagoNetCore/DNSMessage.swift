import Foundation

/// DNS 메시지 만들기·읽기. 기기의 5353 포트에 직접 보내는 mDNS 질의(RFC 6762 §5.5, 6.7)에 쓴다.
/// 필요한 레코드(A, PTR, TXT, SRV)만 풀고 나머지는 `.other`로 둔다.
public enum DNSMessage {
    public enum RecordType {
        public static let a: UInt16 = 1
        public static let ptr: UInt16 = 12
        public static let txt: UInt16 = 16
        public static let srv: UInt16 = 33
    }

    /// 질문 여러 개를 담은 표준 질의(재귀 요청 없음).
    public static func query(id: UInt16, questions: [(name: String, type: UInt16)]) -> [UInt8] {
        var bytes = be16(id) + be16(0) + be16(UInt16(questions.count)) + be16(0) + be16(0) + be16(0)
        for question in questions {
            bytes += encode(name: question.name) + be16(question.type) + be16(1)   // IN
        }
        return bytes
    }

    /// 답(answer·authority·additional)의 레코드들. 답이 아니거나 ID가 다르거나 깨졌으면 빈 배열.
    public static func records(in bytes: [UInt8], id: UInt16? = nil) -> [DNSRecord] {
        guard bytes.count >= 12 else { return [] }
        let responseID = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        let isResponse = bytes[2] & 0x80 != 0
        guard isResponse, id == nil || id == responseID else { return [] }
        let questionCount = Int(read16(bytes, 4))
        let recordCount = Int(read16(bytes, 6)) + Int(read16(bytes, 8)) + Int(read16(bytes, 10))

        var offset = 12
        for _ in 0..<questionCount {
            guard let (_, next) = readName(bytes, at: offset), next + 4 <= bytes.count else { return [] }
            offset = next + 4
        }
        var records: [DNSRecord] = []
        for _ in 0..<recordCount {
            guard let (name, next) = readName(bytes, at: offset), next + 10 <= bytes.count else { break }
            let type = read16(bytes, next)
            let length = Int(read16(bytes, next + 8))
            let start = next + 10
            guard start + length <= bytes.count else { break }
            records.append(DNSRecord(name: name, type: type, data: parseData(bytes, type: type, start: start, length: length)))
            offset = start + length
        }
        return records
    }

    /// 192.168.0.7 → "7.0.168.192.in-addr.arpa"
    public static func reverseName(for address: IPv4) -> String {
        address.octets.reversed().map(String.init).joined(separator: ".") + ".in-addr.arpa"
    }

    private static func parseData(_ bytes: [UInt8], type: UInt16, start: Int, length: Int) -> DNSRecord.Data {
        let end = start + length
        switch type {
        case RecordType.a where length == 4:
            return .a(IPv4(bytes[start], bytes[start + 1], bytes[start + 2], bytes[start + 3]))
        case RecordType.ptr:
            return readName(bytes, at: start).map { .ptr($0.0) } ?? .other
        case RecordType.srv where length >= 7:
            guard let (target, _) = readName(bytes, at: start + 6) else { return .other }
            return .srv(port: read16(bytes, start + 4), target: target)
        case RecordType.txt:
            var entries: [String: String] = [:]
            var cursor = start
            while cursor < end {
                let count = Int(bytes[cursor])
                let textEnd = min(cursor + 1 + count, end)
                let text = String(decoding: bytes[(cursor + 1)..<textEnd], as: UTF8.self)
                if !text.isEmpty {
                    let parts = text.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    entries[parts[0].lowercased()] = parts.count > 1 ? String(parts[1]) : ""
                }
                cursor = textEnd
            }
            return .txt(entries)
        default:
            return .other
        }
    }

    /// 압축 포인터를 따라가며 이름을 읽는다. (이름, 이름 뒤 위치)
    static func readName(_ bytes: [UInt8], at start: Int) -> (String, Int)? {
        var labels: [String] = []
        var offset = start
        var resume: Int?
        var jumps = 0
        while true {
            guard offset < bytes.count else { return nil }
            let length = Int(bytes[offset])
            if length == 0 {
                return (labels.joined(separator: "."), resume ?? offset + 1)
            }
            if length & 0xC0 == 0xC0 {
                guard offset + 1 < bytes.count, jumps < 32 else { return nil }
                if resume == nil { resume = offset + 2 }
                offset = (length & 0x3F) << 8 | Int(bytes[offset + 1])
                jumps += 1
                continue
            }
            guard length <= 63, offset + 1 + length <= bytes.count else { return nil }
            labels.append(String(decoding: bytes[(offset + 1)..<(offset + 1 + length)], as: UTF8.self))
            offset += 1 + length
        }
    }

    static func encode(name: String) -> [UInt8] {
        var bytes: [UInt8] = []
        for label in name.split(separator: ".") {
            let utf8 = Array(label.utf8.prefix(63))
            bytes.append(UInt8(utf8.count))
            bytes += utf8
        }
        return bytes + [0]
    }

    static func be16(_ value: UInt16) -> [UInt8] { [UInt8(value >> 8), UInt8(value & 0xFF)] }

    static func read16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }
}

public struct DNSRecord: Hashable, Sendable {
    public enum Data: Hashable, Sendable {
        case a(IPv4)
        case ptr(String)
        case txt([String: String])
        case srv(port: UInt16, target: String)
        case other
    }

    public let name: String
    public let type: UInt16
    public let data: Data
}

/// NetBIOS 이름 상태 질의(UDP 137). 윈도우 PC·삼바 NAS가 컴퓨터 이름을 알려 준다.
public enum NetBIOS {
    /// 와일드카드 이름("*")에 대한 NBSTAT 질의(50바이트)
    public static func nodeStatusRequest(id: UInt16) -> [UInt8] {
        var bytes = DNSMessage.be16(id) + DNSMessage.be16(0) + DNSMessage.be16(1)
            + DNSMessage.be16(0) + DNSMessage.be16(0) + DNSMessage.be16(0)
        // "*" + 0 15개를 반 바이트씩 'A'에 더해 32글자로(첫 단계 인코딩)
        let name: [UInt8] = [0x2A] + [UInt8](repeating: 0, count: 15)
        bytes.append(0x20)
        for byte in name {
            bytes += [0x41 + (byte >> 4), 0x41 + (byte & 0x0F)]
        }
        bytes.append(0)
        return bytes + DNSMessage.be16(0x21) + DNSMessage.be16(1)
    }

    /// 답에서 컴퓨터 이름(접미사 0x00, 그룹 아님)을 꺼낸다.
    public static func computerName(in bytes: [UInt8]) -> String? {
        nodeStatus(in: bytes)?.name
    }

    /// 답에서 컴퓨터 이름과, 이름 목록 바로 뒤 통계의 첫 6바이트(MAC, "unit ID"). 삼바는 MAC 자리를 0으로 채운다.
    public static func nodeStatus(in bytes: [UInt8]) -> (name: String?, mac: MACAddress?)? {
        guard bytes.count > 12, bytes[2] & 0x80 != 0, DNSMessage.read16(bytes, 6) > 0 else { return nil }
        guard let (_, afterName) = DNSMessage.readName(bytes, at: 12), afterName + 10 < bytes.count else { return nil }
        let dataStart = afterName + 10
        let count = Int(bytes[dataStart])
        var names: [(name: String, suffix: UInt8, isGroup: Bool)] = []
        for index in 0..<count {
            let entry = dataStart + 1 + index * 18
            guard entry + 18 <= bytes.count else { break }
            let raw = bytes[entry..<(entry + 15)].filter { $0 != 0 }
            let name = String(decoding: raw, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            names.append((name, bytes[entry + 15], bytes[entry + 16] & 0x80 != 0))
        }
        let unique = names.filter { !$0.isGroup && !$0.name.isEmpty }
        let name = (unique.first { $0.suffix == 0x00 } ?? unique.first { $0.suffix == 0x20 } ?? unique.first)?.name
        let macStart = dataStart + 1 + count * 18
        let mac = macStart + 6 <= bytes.count ? MACAddress(Array(bytes[macStart..<(macStart + 6)])) : nil
        return (name, mac)
    }
}
