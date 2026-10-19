/// SNMPv2c로 공유기·AP의 ARP 표(IP → MAC)를 읽는다.
///
/// iOS 앱은 자기 ARP 표를 못 읽지만, 공유기는 같은 Wi-Fi의 모든 기기 MAC을 알고 있다. SNMP가 켜진
/// 공유기·관리형 AP(커뮤니티 문자열을 알 때)에 UDP 161로 묻는다. 멀티캐스트가 아니라 entitlement가 필요 없다.
public enum SNMP {
    /// ipNetToMediaPhysAddress(옛 ARP 표): .1.3.6.1.2.1.4.22.1.2.<ifIndex>.<a>.<b>.<c>.<d> = MAC
    public static let arpTable: [UInt32] = [1, 3, 6, 1, 2, 1, 4, 22, 1, 2]
    /// ipNetToPhysicalPhysAddress(새 표): .1.3.6.1.2.1.4.35.1.4.<ifIndex>.1.4.<a>.<b>.<c>.<d> = MAC
    public static let physicalTable: [UInt32] = [1, 3, 6, 1, 2, 1, 4, 35, 1, 4]
    /// ipAdEntIfIndex: .1.3.6.1.2.1.4.20.1.2.<a>.<b>.<c>.<d> = 그 IP가 붙은 인터페이스 번호
    public static let addressInterface: [UInt32] = [1, 3, 6, 1, 2, 1, 4, 20, 1, 2]
    /// ifPhysAddress: .1.3.6.1.2.1.2.2.1.6.<ifIndex> = 그 인터페이스의 MAC
    public static let interfaceMAC: [UInt32] = [1, 3, 6, 1, 2, 1, 2, 2, 1, 6]

    public enum Value: Hashable, Sendable {
        case octets([UInt8])
        case integer(Int64)
        /// 표 끝(endOfMibView)·없음(noSuchObject·noSuchInstance)
        case end
        case other
    }

    public struct VarBind: Hashable, Sendable {
        public let oid: [UInt32]
        public let value: Value
    }

    /// Get 요청(v2c): 정확히 그 OID들의 값
    public static func get(community: String, requestID: Int32, oids: [[UInt32]]) -> [UInt8] {
        let varBinds = oids.flatMap { tlv(0x30, encodeOID($0) + [0x05, 0x00]) }
        let pdu = tlv(0xA0, encodeInteger(Int64(requestID)) + encodeInteger(0) + encodeInteger(0) + tlv(0x30, varBinds))
        return tlv(0x30, encodeInteger(1) + tlv(0x04, Array(community.utf8)) + pdu)
    }

    /// GetBulk 요청(v2c)
    public static func getBulk(community: String, requestID: Int32, oid: [UInt32], maxRepetitions: Int32) -> [UInt8] {
        let varBind = tlv(0x30, encodeOID(oid) + [0x05, 0x00])
        let pdu = tlv(0xA5, encodeInteger(Int64(requestID)) + encodeInteger(0) + encodeInteger(Int64(maxRepetitions))
            + tlv(0x30, varBind))
        return tlv(0x30, encodeInteger(1) + tlv(0x04, Array(community.utf8)) + pdu)
    }

    /// 응답(GetResponse) 해석. 요청 번호가 다르거나 오류 상태거나 깨졌으면 nil.
    public static func parseResponse(_ bytes: [UInt8], requestID: Int32) -> [VarBind]? {
        guard let message = readTLV(bytes, at: 0), message.tag == 0x30 else { return nil }
        let fields = readSequence(bytes, message.range)
        guard fields.count == 3, fields[2].tag == 0xA2 else { return nil }
        let pdu = readSequence(bytes, fields[2].range)
        guard pdu.count == 4, decodeInteger(bytes, pdu[0].range) == Int64(requestID),
              decodeInteger(bytes, pdu[1].range) == 0, pdu[3].tag == 0x30 else { return nil }
        var result: [VarBind] = []
        for item in readSequence(bytes, pdu[3].range) where item.tag == 0x30 {
            let parts = readSequence(bytes, item.range)
            guard parts.count == 2, parts[0].tag == 0x06 else { continue }
            let oid = decodeOID(Array(bytes[parts[0].range]))
            let value: Value
            switch parts[1].tag {
            case 0x04: value = .octets(Array(bytes[parts[1].range]))
            case 0x02: value = .integer(decodeInteger(bytes, parts[1].range) ?? 0)
            case 0x80, 0x81, 0x82: value = .end
            default: value = .other
            }
            result.append(VarBind(oid: oid, value: value))
        }
        return result
    }

    /// ARP 표 한 줄을 (IP, MAC)으로. 옛 표와 새 표 모두.
    public static func arpEntry(_ varBind: VarBind) -> (IPv4, MACAddress)? {
        guard case .octets(let bytes) = varBind.value, let mac = MACAddress(bytes) else { return nil }
        let oid = varBind.oid
        if oid.starts(with: arpTable), oid.count == arpTable.count + 5 {
            return ipv4(oid.suffix(4)).map { ($0, mac) }
        }
        if oid.starts(with: physicalTable), oid.count == physicalTable.count + 7,
           oid[physicalTable.count + 1] == 1, oid[physicalTable.count + 2] == 4 {
            return ipv4(oid.suffix(4)).map { ($0, mac) }
        }
        return nil
    }

    private static func ipv4(_ parts: ArraySlice<UInt32>) -> IPv4? {
        let octets = parts.compactMap { UInt8(exactly: $0) }
        return octets.count == 4 ? IPv4(octets[0], octets[1], octets[2], octets[3]) : nil
    }

    // MARK: BER

    struct TLV {
        let tag: UInt8
        /// 내용의 범위
        let range: Range<Int>
    }

    static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        [tag] + encodeLength(content.count) + content
    }

    static func encodeLength(_ length: Int) -> [UInt8] {
        if length < 0x80 { return [UInt8(length)] }
        var bytes: [UInt8] = []
        var rest = length
        while rest > 0 {
            bytes.insert(UInt8(rest & 0xFF), at: 0)
            rest >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    static func encodeInteger(_ value: Int64) -> [UInt8] {
        var bytes = withUnsafeBytes(of: value.bigEndian, Array.init)
        // 부호를 지키며 앞의 군더더기 바이트를 뺀다
        while bytes.count > 1,
              (bytes[0] == 0x00 && bytes[1] & 0x80 == 0) || (bytes[0] == 0xFF && bytes[1] & 0x80 != 0) {
            bytes.removeFirst()
        }
        return tlv(0x02, bytes)
    }

    static func encodeOID(_ oid: [UInt32]) -> [UInt8] {
        guard oid.count >= 2 else { return tlv(0x06, []) }
        var bytes = [UInt8(oid[0] * 40 + oid[1])]
        for component in oid.dropFirst(2) {
            var chunk = [UInt8(component & 0x7F)]
            var rest = component >> 7
            while rest > 0 {
                chunk.insert(UInt8(rest & 0x7F) | 0x80, at: 0)
                rest >>= 7
            }
            bytes += chunk
        }
        return tlv(0x06, bytes)
    }

    static func decodeOID(_ bytes: [UInt8]) -> [UInt32] {
        guard let first = bytes.first else { return [] }
        var oid: [UInt32] = [UInt32(first) / 40, UInt32(first) % 40]
        var value: UInt32 = 0
        for byte in bytes.dropFirst() {
            value = value << 7 | UInt32(byte & 0x7F)
            if byte & 0x80 == 0 {
                oid.append(value)
                value = 0
            }
        }
        return oid
    }

    static func decodeInteger(_ bytes: [UInt8], _ range: Range<Int>) -> Int64? {
        guard !range.isEmpty, range.count <= 8 else { return nil }
        var value: Int64 = bytes[range.lowerBound] & 0x80 != 0 ? -1 : 0
        for index in range {
            value = value << 8 | Int64(bytes[index])
        }
        return value
    }

    static func readTLV(_ bytes: [UInt8], at offset: Int) -> TLV? {
        guard offset + 2 <= bytes.count else { return nil }
        let tag = bytes[offset]
        var cursor = offset + 1
        var length = Int(bytes[cursor])
        cursor += 1
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard (1...4).contains(count), cursor + count <= bytes.count else { return nil }
            length = 0
            for _ in 0..<count {
                length = length << 8 | Int(bytes[cursor])
                cursor += 1
            }
        }
        guard cursor + length <= bytes.count else { return nil }
        return TLV(tag: tag, range: cursor..<(cursor + length))
    }

    static func readSequence(_ bytes: [UInt8], _ range: Range<Int>) -> [TLV] {
        var items: [TLV] = []
        var cursor = range.lowerBound
        while cursor < range.upperBound, let item = readTLV(bytes, at: cursor), item.range.upperBound <= range.upperBound {
            items.append(item)
            cursor = item.range.upperBound
        }
        return items
    }
}

/// 공유기·AP의 ARP 표를 SNMP GetBulk로 끝까지 읽는다.
public struct ARPTableReader: Sendable {
    private let transport: any DatagramExchanging
    private let timeout: Duration

    public init(transport: any DatagramExchanging, timeout: Duration = .milliseconds(1500)) {
        self.transport = transport
        self.timeout = timeout
    }

    /// IP → MAC. 답이 없으면(SNMP 꺼짐·커뮤니티 틀림) nil
    public func read(from router: IPv4, community: String) async -> [IPv4: MACAddress]? {
        if let table = await walk(SNMP.arpTable, router: router, community: community), !table.isEmpty {
            return table
        }
        return await walk(SNMP.physicalTable, router: router, community: community)
    }

    private func walk(_ base: [UInt32], router: IPv4, community: String) async -> [IPv4: MACAddress]? {
        var table: [IPv4: MACAddress] = [:]
        var next = base
        for _ in 0..<64 {
            let id = Int32.random(in: 1...Int32.max)
            let request = SNMP.getBulk(community: community, requestID: id, oid: next, maxRepetitions: 24)
            guard let reply = await transport.exchange(request, with: router, port: 161, timeout: timeout),
                  let varBinds = SNMP.parseResponse(reply, requestID: id) else {
                // 첫 질문부터 답이 없으면 SNMP를 못 쓰는 것
                return next == base ? nil : table
            }
            var advanced = false
            for varBind in varBinds {
                guard varBind.oid.starts(with: base), varBind.value != .end else { return table }
                if let (ip, mac) = SNMP.arpEntry(varBind) { table[ip] = mac }
                next = varBind.oid
                advanced = true
            }
            guard advanced else { return table }
        }
        return table
    }
}
