import Foundation
import Combine

/// The monthly budget for Claude corrections: the current month's total, kept in UserDefaults. Every paid correction
/// counts (including rejected ones and the test in settings); at 80% a warning appears, at 100% correction stops
/// until the next month (see DictationController).
@MainActor
final class BudgetTracker: ObservableObject {
    @Published private(set) var spend: MonthlySpend

    private static let key = "monthlySpend"
    private let defaults: UserDefaults

    /// `initialSpend`: on the first launch with the budget, what has already been spent this month (from the history).
    init(defaults: UserDefaults = .standard, initialSpend: Double) {
        self.defaults = defaults
        let now = Date()
        if let data = defaults.data(forKey: Self.key), let saved = try? JSONDecoder().decode(MonthlySpend.self, from: data) {
            spend = saved.current(at: now)
        } else {
            spend = MonthlySpend(month: MonthlySpend.monthKey(for: now), spentUSD: initialSpend)
            save()
        }
    }

    /// The estimated total for the current month (zero after the month changes).
    var spentThisMonth: Double { spend.current(at: Date()).spentUSD }

    func status(limit: Double?) -> BudgetStatus {
        BudgetStatus.of(spent: spentThisMonth, limit: limit)
    }

    /// Adds the cost of a correction. Returns true when 80% of the budget has just been crossed (once a month).
    @discardableResult
    func add(_ cost: Double?, limit: Double?) -> Bool {
        guard let cost, cost > 0 else { return false }
        let result = spend.adding(cost, limit: limit, at: Date())
        spend = result.spend
        save()
        return result.crossedWarning
    }

    /// The day correction starts again after the budget was reached: "December 1".
    static func resumeDay(now: Date = Date()) -> String {
        let calendar = Calendar.current
        let start = calendar.dateInterval(of: .month, for: now)?.end ?? now
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMMM d"
        return formatter.string(from: start)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(spend) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
