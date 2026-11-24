import XCTest
@testable import HauDiCore

final class BudgetTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Bucharest")!
        return calendar
    }

    private func date(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text)!
    }

    func testStatus() {
        XCTAssertEqual(BudgetStatus.of(spent: 3, limit: 20), .ok)
        XCTAssertEqual(BudgetStatus.of(spent: 15.99, limit: 20), .ok)
        XCTAssertEqual(BudgetStatus.of(spent: 16, limit: 20), .warning)
        XCTAssertEqual(BudgetStatus.of(spent: 20, limit: 20), .exceeded)
        XCTAssertEqual(BudgetStatus.of(spent: 50, limit: nil), .off)
        XCTAssertEqual(BudgetStatus.of(spent: 50, limit: 0), .off)
    }

    func testWarningOncePerMonthAndReset() {
        let start = MonthlySpend(month: "2026-11", spentUSD: 15)
        let now = date("2026-11-23 22:00")
        XCTAssertEqual(MonthlySpend.monthKey(for: now, calendar: calendar), "2026-11")

        let first = start.adding(0.5, limit: 20, at: now, calendar: calendar)
        XCTAssertFalse(first.crossedWarning)
        let second = first.spend.adding(0.6, limit: 20, at: now, calendar: calendar)
        XCTAssertTrue(second.crossedWarning)
        XCTAssertEqual(second.spend.spentUSD, 16.1, accuracy: 1e-9)
        // Avertismentul apare o singura data pe luna, chiar si cand se trece de 100%.
        let third = second.spend.adding(10, limit: 20, at: now, calendar: calendar)
        XCTAssertFalse(third.crossedWarning)
        XCTAssertEqual(BudgetStatus.of(spent: third.spend.spentUSD, limit: 20), .exceeded)

        // Luna noua (1 decembrie, 00:05 la Bucuresti): de la zero, cu avertismentul din nou posibil.
        let december = date("2026-12-01 00:05")
        let reset = third.spend.current(at: december, calendar: calendar)
        XCTAssertEqual(reset, MonthlySpend(month: "2026-12"))
        let afterReset = third.spend.adding(17, limit: 20, at: december, calendar: calendar)
        XCTAssertEqual(afterReset.spend.month, "2026-12")
        XCTAssertEqual(afterReset.spend.spentUSD, 17, accuracy: 1e-9)
        XCTAssertTrue(afterReset.crossedWarning)
    }

    func testNoLimitNeverWarnsAndIgnoresNegativeCost() {
        let spend = MonthlySpend(month: "2026-11", spentUSD: 100)
        let now = date("2026-11-23 22:00")
        XCTAssertFalse(spend.adding(5, limit: nil, at: now, calendar: calendar).crossedWarning)
        XCTAssertEqual(spend.adding(-3, limit: 20, at: now, calendar: calendar).spend.spentUSD, 100, accuracy: 1e-9)
    }
}
