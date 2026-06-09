import Foundation

/// Apple-epoch (2001-01-01) → Unix-epoch conversions. chat.db stores
/// `message.date` in nanoseconds on modern macOS, seconds on very old DBs;
/// detect by magnitude. See PLAN §14.
public enum AppleDate {
    public static let epochOffset: Double = 978_307_200  // seconds, 2001→1970

    /// Raw chat.db `date` value → Unix seconds (Double).
    public static func toUnix(_ raw: Int64) -> Double {
        let secs = raw > 1_000_000_000_000 ? Double(raw) / 1e9 : Double(raw)
        return secs + epochOffset
    }

    /// Unix seconds → Apple-epoch nanoseconds (for building WHERE clauses against
    /// chat.db `date`). Modern DBs use ns; we always emit ns.
    public static func unixToAppleNanos(_ unix: Double) -> Int64 {
        Int64((unix - epochOffset) * 1e9)
    }
}
