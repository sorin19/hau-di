import Foundation

/// How much was spent on Claude corrections in the current month (estimated from tokens x list price).
/// Kept separate from the history, so the budget still counts when the history is turned off or cleared.
public struct MonthlySpend: Codable, Equatable, Sendable {
    /// The month, "2026-11".
    public var month: String
    public var spentUSD: Double
    /// The 80% warning has been shown this month.
    public var warned: Bool

    public init(month: String, spentUSD: Double = 0, warned: Bool = false) {
        self.month = month
        self.spentUSD = spentUSD
        self.warned = warned
    }

    public static func monthKey(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    /// The same state within its month; in a new month, a fresh one starting from zero.
    public func current(at date: Date, calendar: Calendar = .current) -> MonthlySpend {
        let key = Self.monthKey(for: date, calendar: calendar)
        return key == month ? self : MonthlySpend(month: key)
    }

    /// Adds the cost of a correction. `crossedWarning`: spending just crossed 80% of the budget (only once a month).
    public func adding(_ cost: Double, limit: Double?, at date: Date,
                       calendar: Calendar = .current) -> (spend: MonthlySpend, crossedWarning: Bool) {
        var next = current(at: date, calendar: calendar)
        next.spentUSD += max(0, cost)
        guard !next.warned, BudgetStatus.of(spent: next.spentUSD, limit: limit) != .ok,
              BudgetStatus.of(spent: next.spentUSD, limit: limit) != .off else {
            return (next, false)
        }
        next.warned = true
        return (next, true)
    }
}

/// The monthly budget status: no limit, under 80%, from 80% on (warning), reached (correction stops).
public enum BudgetStatus: Equatable, Sendable {
    case off, ok, warning, exceeded

    public static let warningFraction = 0.8

    public static func of(spent: Double, limit: Double?) -> BudgetStatus {
        guard let limit, limit > 0 else { return .off }
        if spent >= limit { return .exceeded }
        if spent >= limit * warningFraction { return .warning }
        return .ok
    }
}
