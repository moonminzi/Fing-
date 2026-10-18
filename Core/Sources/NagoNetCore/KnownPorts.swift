/// 잘 알려진 TCP 포트의 서비스 이름.
public enum KnownPorts {
    public static let names: [UInt16: String] = [
        22: "SSH",
        80: "HTTP",
        443: "HTTPS",
        445: "SMB(파일 공유)",
        548: "AFP(Mac 파일 공유)",
        7000: "AirPlay",
        8080: "HTTP 대체",
        62078: "iPhone 동기화(lockdown)",
    ]

    public static func name(for port: UInt16) -> String? {
        names[port]
    }
}
