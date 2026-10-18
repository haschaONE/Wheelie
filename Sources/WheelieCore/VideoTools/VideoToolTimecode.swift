import Foundation

/// Time formatting and parsing shared by the video editors.
public enum VideoToolTimecode {
    /// Longest duration taken seriously (about 115 days). Larger values come from damaged or
    /// crafted files; they are treated as missing, and formatting clamps to this.
    public static let maximumSeconds: Double = 10_000_000

    /// Finite, non-negative and at most `maximumSeconds`, so whole-number conversions can't trap.
    static func clamped(_ seconds: Double) -> Double {
        seconds.isFinite ? min(max(0, seconds), maximumSeconds) : 0
    }

    /// `65.25` -> "1:05.25"; `3725` -> "1:02:05.00".
    public static func format(_ seconds: Double, fractionDigits: Int = 2) -> String {
        let digits = max(0, min(fractionDigits, 3))
        let scale = Int(pow(10, Double(digits)))
        let total = Int((clamped(seconds) * Double(scale)).rounded())
        let fraction = total % scale
        let whole = total / scale
        let h = whole / 3600, m = (whole % 3600) / 60, s = whole % 60
        var text = h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
        if digits > 0 { text += "." + String(format: "%0\(digits)d", fraction) }
        return text
    }

    /// Accepts "12", "12.5", "12.5s", "1:05.25", "1:02:05". Returns nil for anything else.
    public static func parse(_ text: String) -> Double? {
        var t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        if t.hasSuffix("s") { t.removeLast() }
        guard !t.isEmpty else { return nil }
        let parts = t.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for (index, part) in parts.enumerated() {
            let isLast = index == parts.count - 1
            guard !part.isEmpty, let value = isLast ? Double(part) : Double(Int(part) ?? -1),
                  value >= 0, value.isFinite else { return nil }
            if !isLast, index > 0, value >= 60 { return nil }
            if isLast, parts.count > 1, value >= 60 { return nil }
            total = total * 60 + value
        }
        return total <= maximumSeconds ? total : nil
    }

    /// File-name stamp for a snapshot: "00m12s", or "1h02m12s" past an hour.
    public static func fileStamp(_ seconds: Double) -> String {
        let whole = Int(clamped(seconds).rounded(.down))
        let h = whole / 3600, m = (whole % 3600) / 60, s = whole % 60
        return h > 0 ? String(format: "%dh%02dm%02ds", h, m, s) : String(format: "%02dm%02ds", m, s)
    }

    /// Plain number without trailing zeros: 2 -> "2", 0.25 -> "0.25", 1.5 -> "1.5".
    public static func compact(_ value: Double, maxFractionDigits: Int = 3) -> String {
        var text = String(format: "%.\(maxFractionDigits)f", value)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text == "-0" ? "0" : text
    }
}
