import Foundation
import Combine

/// Bugetul lunar al corecturilor Claude: suma lunii curente, pastrata in UserDefaults. Se numara toate corecturile
/// platite (si cele respinse, si testul din setari); la 80% apare un avertisment, la 100% corectia se opreste
/// pana la luna urmatoare (vezi DictationController).
@MainActor
final class BudgetTracker: ObservableObject {
    @Published private(set) var spend: MonthlySpend

    private static let key = "monthlySpend"
    private let defaults: UserDefaults

    /// `initialSpend`: la prima pornire cu bugetul, ce s-a cheltuit deja luna asta (din istoric).
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

    /// Suma estimata a lunii curente (zero dupa schimbarea lunii).
    var spentThisMonth: Double { spend.current(at: Date()).spentUSD }

    func status(limit: Double?) -> BudgetStatus {
        BudgetStatus.of(spent: spentThisMonth, limit: limit)
    }

    /// Adauga costul unei corecturi. Intoarce true cand tocmai s-a trecut de 80% din buget (o data pe luna).
    @discardableResult
    func add(_ cost: Double?, limit: Double?) -> Bool {
        guard let cost, cost > 0 else { return false }
        let result = spend.adding(cost, limit: limit, at: Date())
        spend = result.spend
        save()
        return result.crossedWarning
    }

    /// Ziua in care corectia porneste din nou dupa ce bugetul a fost atins: "1 decembrie".
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
