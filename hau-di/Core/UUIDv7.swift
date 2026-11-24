import Foundation

/// UUID versiunea 7 (RFC 9562): primii 48 de biti sunt momentul generarii (milisecunde Unix), urmati de versiune,
/// varianta si 74 de biti aleatori din generatorul criptografic al sistemului. Se ordoneaza in timp, iar din primele
/// 12 cifre hexa se poate citi cand a fost generat.
public enum UUIDv7 {
    public static func make(date: Date = Date()) -> UUID {
        var bytes = (0..<16).map { _ in UInt8.random(in: .min ... .max) }
        let milliseconds = UInt64(max(0, (date.timeIntervalSince1970 * 1000).rounded(.down)))
        for index in 0..<6 {
            bytes[index] = UInt8(truncatingIfNeeded: milliseconds >> (8 * (5 - index)))
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x70   // versiunea 7
        bytes[8] = (bytes[8] & 0x3F) | 0x80   // varianta RFC (10xx)
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// Textul e un UUID v7 (versiunea 7, varianta RFC), cu litere mari sau mici.
    public static func isValid(_ text: String) -> Bool {
        guard let uuid = UUID(uuidString: text) else { return false }
        return uuid.uuid.6 >> 4 == 7 && uuid.uuid.8 & 0xC0 == 0x80
    }

    /// Momentul generarii, din primii 48 de biti.
    public static func date(of uuid: UUID) -> Date {
        let b = uuid.uuid
        let milliseconds = [b.0, b.1, b.2, b.3, b.4, b.5].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        return Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }
}
