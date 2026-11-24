import Foundation

/// Cat s-a cheltuit pe corecturile Claude in luna curenta (estimat din tokeni x pretul de lista).
/// Se tine separat de istoric, ca bugetul sa conteze si cand istoricul e oprit sau sters.
public struct MonthlySpend: Codable, Equatable, Sendable {
    /// Luna, "2026-11".
    public var month: String
    public var spentUSD: Double
    /// Avertismentul de 80% a fost aratat luna asta.
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

    /// Aceeasi stare in luna ei; intr-o luna noua, alta, de la zero.
    public func current(at date: Date, calendar: Calendar = .current) -> MonthlySpend {
        let key = Self.monthKey(for: date, calendar: calendar)
        return key == month ? self : MonthlySpend(month: key)
    }

    /// Adauga costul unei corecturi. `crossedWarning`: tocmai s-a trecut de 80% din buget (o singura data pe luna).
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

/// Starea bugetului lunar: fara limita, sub 80%, de la 80% (avertisment), atins (corectia se opreste).
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
