import Foundation

/// UUID version 7 (RFC 9562): the first 48 bits are the generation time (Unix milliseconds), followed by the version,
/// the variant and 74 random bits from the system's cryptographic generator. It sorts by time, and the first
/// 12 hex digits show when it was generated.
public enum UUIDv7 {
    public static func make(date: Date = Date()) -> UUID {
        var bytes = (0..<16).map { _ in UInt8.random(in: .min ... .max) }
        let milliseconds = UInt64(max(0, (date.timeIntervalSince1970 * 1000).rounded(.down)))
        for index in 0..<6 {
            bytes[index] = UInt8(truncatingIfNeeded: milliseconds >> (8 * (5 - index)))
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x70   // version 7
        bytes[8] = (bytes[8] & 0x3F) | 0x80   // RFC variant (10xx)
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// The text is a v7 UUID (version 7, RFC variant), in upper or lower case.
    public static func isValid(_ text: String) -> Bool {
        guard let uuid = UUID(uuidString: text) else { return false }
        return uuid.uuid.6 >> 4 == 7 && uuid.uuid.8 & 0xC0 == 0x80
    }

    /// The generation time, from the first 48 bits.
    public static func date(of uuid: UUID) -> Date {
        let b = uuid.uuid
        let milliseconds = [b.0, b.1, b.2, b.3, b.4, b.5].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        return Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }
}
