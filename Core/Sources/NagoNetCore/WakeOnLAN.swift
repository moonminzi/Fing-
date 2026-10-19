/// Wake-on-LAN: 꺼져 있거나 잠든 기기를 깨우는 "매직 패킷"을 만든다.
///
/// 매직 패킷은 0xFF 여섯 바이트 뒤에 대상 MAC을 16번 이어 붙인 102바이트다. 기기의 네트워크 카드가
/// 저전력 상태에서도 이 패턴을 알아보고 전원을 켠다. 보내는 쪽(UDP 포트 9 또는 7)은 앱에서 한다.
public enum WakeOnLAN {
    /// 흔히 쓰는 포트: 9(discard), 7(echo)
    public static let ports: [UInt16] = [9, 7]

    public static func magicPacket(for mac: MACAddress) -> [UInt8] {
        [UInt8](repeating: 0xFF, count: 6) + Array(repeating: mac.bytes, count: 16).flatMap { $0 }
    }
}
