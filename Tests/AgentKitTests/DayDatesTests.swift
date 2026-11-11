import Foundation
import Testing
@testable import AgentKit

/// The dates the "Your day" page is built around.
struct DayDatesTests {
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return calendar
    }

    func date(_ day: Int, _ hour: Int = 9, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    /// Monday 9 Nov's morning shows Friday's work, not an empty weekend.
    @Test func theLastWorkdaySkipsEmptyDays() {
        let worked: Set<Int> = [6]   // Friday
        let day = DayDates.lastWorkday(before: date(9), calendar: calendar) {
            worked.contains(calendar.component(.day, from: $0))
        }
        #expect(day.map { calendar.component(.day, from: $0) } == 6)
        #expect(DayDates.lastWorkday(before: date(9), calendar: calendar) { _ in false } == nil)
        // Yesterday when there was work yesterday.
        #expect(DayDates.lastWorkday(before: date(10), calendar: calendar) { _ in true }
            .map { calendar.component(.day, from: $0) } == 9)
    }

    @Test func daysAreNamedAsPeopleSayThem() {
        let now = date(10, 8)
        #expect(DayDates.name(of: date(10, 1), now: now, calendar: calendar) == "Today")
        #expect(DayDates.name(of: date(9, 23), now: now, calendar: calendar) == "Yesterday")
        #expect(!["Today", "Yesterday"].contains(DayDates.name(of: date(6), now: now, calendar: calendar)))
    }

    @Test func lengthsReadNaturally() {
        #expect(DayDates.length(45 * 60) == "45 min")
        #expect(DayDates.length(125 * 60) == "2 h 5 min")
        #expect(DayDates.length(3600) == "1 h")
        #expect(DayDates.length(10) == "1 min")
    }

    @Test func dueTimesSayHowSoon() {
        let now = date(10, 12)
        #expect(DayDates.due(date(10, 16), now: now, calendar: calendar).hasPrefix("today"))
        #expect(DayDates.due(date(11, 10), now: now, calendar: calendar).hasPrefix("tomorrow"))
        #expect(DayDates.due(date(10, 9), now: now, calendar: calendar).hasPrefix("was due"))
        #expect(DayDates.due(date(8, 9), now: now, calendar: calendar).hasPrefix("overdue since"))
    }

    /// 10 Nov: work from 9:33 PM to 5:29 AM read as "Today · 10 h 47 min". A night's work is one session.
    @Test func aNightsWorkIsOneSession() {
        let spans = [(start: date(9, 21, 33), end: date(10, 0, 23)), (start: date(10, 0, 44), end: date(10, 1, 38)),
                     (start: date(10, 2, 51), end: date(10, 5, 29)),
                     // Back after sleeping: a new session.
                     (start: date(10, 11, 40), end: date(10, 12, 50))]
        let sessions = DayDates.sessions(spans)
        #expect(sessions == [0..<3, 3..<4])
        #expect(DayDates.sessions([]).isEmpty)
        #expect(DayDates.sessions([spans[0]]) == [0..<1])
    }

    @Test func sessionsAreNamedByWhenTheyHappened() {
        let now = date(10, 13)
        #expect(DayDates.sessionName(start: date(9, 21, 33), end: date(10, 5, 29), now: now, calendar: calendar) == "Last night")
        #expect(DayDates.sessionName(start: date(10, 11, 40), end: date(10, 12, 50), now: now, calendar: calendar) == "Today so far")
        #expect(DayDates.sessionName(start: date(10, 9), end: date(10, 10), now: date(10, 18), calendar: calendar) == "Earlier today")
        #expect(DayDates.sessionName(start: date(9, 10), end: date(9, 17), now: now, calendar: calendar) == "Yesterday")
        #expect(DayDates.sessionName(start: date(9, 22), end: date(10, 11), now: date(10, 12), calendar: calendar).hasPrefix("Since"))
    }

    @Test func outcomesBecomeTags() {
        #expect(DayDates.tag("still open") == "Still open")
        #expect(DayDates.tag("released.") == "Released")
        #expect(DayDates.tag("") == "")
    }

    /// From the 10 Nov page: only finished work gets a tag; "still open" gets nothing; a sentence isn't a tag.
    @Test func onlyFinishedWorkIsTagged() {
        for finished in ["done", "Released", "Solved", "booked", "Fixed and deployed"] {
            #expect(DayDates.isFinished(finished), "\(finished)")
        }
        for notFinished in ["Still open", "Discussion continued without resolution", "not sent", "The run is clear",
                            "Fixes implemented for mistake detection, with changes in the works", ""] {
            #expect(!DayDates.isFinished(notFinished), "\(notFinished)")
        }
        #expect(DayDates.isStillGoing("Still open"))
        #expect(DayDates.isStillGoing("in progress."))
        #expect(DayDates.isStillGoing(""))
        #expect(!DayDates.isStillGoing("The run is clear"))
    }
}
