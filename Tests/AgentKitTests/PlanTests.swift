import Foundation
import Testing
@testable import AgentKit

/// A flight booked and checked in on the airline's site (2026-11-06): it has to come back as a plan with its
/// deadlines, not be refused as "a website", and an offer on the same site must not.
struct PlanTests {
    let now = Date()
    var itinerary: Journal.Snapshot {
        Journal.Snapshot(id: 268, app: "Google Chrome", title: "Itinerary - Google Chrome", url: "https://www.goindigo.in/book/itinerary.html",
                         domain: "goindigo.in", text: """
                            CHECK FLIGHT STATUS | Sun, 08 Nov | Your | Itinerary | Hello | Shubham Agrawal | Your itinerary is generated
                            BLR RPR | 08 Nov, 26 | 1 Pax | Confirmed | Departure Flight | BLR | BENGALURU (T1) | 1 Stop | RPR | RAIPUR
                            Passengers and Add-ons | Fast Forward | Check-in closes | 09:15 | 10:15 | Sun, 08 Nov 2026 | 6E 537 | 6E 7575
                            Web Check-in | Check-in online for free 48hrs to 60mins before the flight | Starts on 10:15, Fri 06 Nov
                            """, first: now, last: now, seconds: 120, sightings: 1)
    }
    var offers: Journal.Snapshot {
        Journal.Snapshot(id: 260, app: "Google Chrome", title: "Flight Offers, Deals | IndiGo", url: "https://www.goindigo.in/offers",
                         domain: "goindigo.in", text: "Use Code: 6EMLE Get flat 10% off on flights to Maldives. Book flights and earn BluChips.",
                         first: now, last: now, seconds: 20, sightings: 1)
    }

    @Test func plansKeepTheirTime() {
        let reading = Consolidator.parse("""
            {"memories": [], "promises": [
              {"summary": "Flight 6E 537 Bengaluru to Raipur, T1", "kind": "plan", "due": "2026-11-08 10:15", "status": "open"},
              {"summary": "Web check-in opens for 6E 537", "kind": "plan", "due": "2026-11-06T10:15", "status": "open"},
              {"summary": "Send Priya the deck", "kind": "promised", "due": "2026-11-10", "status": "open"}]}
            """)
        let back = DateFormatter()
        back.dateFormat = "d HH mm"
        back.locale = Locale(identifier: "en_US_POSIX")
        let parts = reading.promises.map { p in p.due.map { back.string(from: $0).split(separator: " ").compactMap { Int($0) } } }
            .map { $0.map { (day: $0[0], hour: $0[1], minute: $0[2]) } }
        #expect(reading.promises.map(\.kind) == ["plan", "plan", "promised"])
        #expect(parts[0]?.day == 8 && parts[0]?.hour == 10 && parts[0]?.minute == 15)
        #expect(parts[1]?.day == 6 && parts[1]?.hour == 10)
        #expect(parts[2]?.hour == 23)   // a day without a time: through that day
    }

    @Test func aBookingOnYourOwnPageIsAPlan() {
        let due = Date().addingTimeInterval(2 * 86400)
        let flight = Journal.Promise(summary: "Flight 6E 537 Bengaluru to Raipur, T1", mine: true, due: due, kind: "plan")
        let checkIn = Journal.Promise(summary: "Check-in closes for 6E 537", mine: true, due: due, kind: "plan")
        let maldives = Journal.Promise(summary: "Flight to Maldives with code 6EMLE", mine: true, due: due, kind: "plan")
        let undated = Journal.Promise(summary: "Flight 6E 537 Bengaluru to Raipur", mine: true, kind: "plan")
        let kept = Consolidator.judge(promises: [flight, checkIn, maldives, undated], seen: [itinerary, offers],
                                      me: ["Shubham Agrawal", "Shubham"]) { _ in [] }
        #expect(kept.map(\.summary) == [flight.summary, checkIn.summary])
        // Somebody else's itinerary (a page that never names the user) isn't the user's plan.
        #expect(Consolidator.judge(promises: [flight], seen: [itinerary], me: ["Priya Shah"]) { _ in [] }.isEmpty)
    }

    @Test func trivialStatusDoesNotReplaceWhatMattered() {
        #expect(Consolidator.isActivity("Shubham is checking the status of his payment and has been advised not to pay twice."))
        #expect(Consolidator.isActivity("Shubham is considering a flight to Maldives with IndiGo using the 6EMLE code."))
        #expect(Consolidator.singleValued.contains("employer") && !Consolidator.singleValued.contains("status"))
    }
}

/// The small model's real answers about those pages (Qwen3 1.7B, 2026-11-06), checked against the pages.
struct PlanCheckTests {
    let today: Date = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: "2026-11-06 02:45")!
    }()
    let pdf = "Itinerary PDF\nMr Shubham Agrawal | BLR - Kempegowda International Airport | (Terminal 1) | 10:15 hrs, 08 Nov 2026 | "
        + "Hyderabad | 11:35 hrs, 08 Nov 2026 | 15:25 hrs, 08 Nov 2026 | 6E 537 (A320) 08 Nov 2026 Check-in/Bag Drop Closes: 09:15 hrs"

    @Test func whatThePageSaysIsKept() {
        let answer = #"{"plans": [{"what": "Flight 6E 537 Bengaluru to Raipur, Terminal 1", "when": "2026-11-08 10:15"}, {"what": "Check-in closes", "when": "2026-11-08 09:15"}]}"#
        let plans = Consolidator.checkedPlans(answer, page: pdf, now: today)
        #expect(plans.map(\.summary) == ["Flight 6E 537 Bengaluru to Raipur, Terminal 1", "Check-in closes: Flight 6E 537 Bengaluru to Raipur"])
        #expect(plans.allSatisfy { $0.kind == "plan" && $0.due != nil })
    }

    @Test func timesThePageDoesNotHaveAreNot() {
        // 02:43 was when the window was seen, not on the page; 9 Nov isn't on it; check-in can't close after take-off.
        let answer = #"{"plans": [{"what": "Flight 6E 537 Bengaluru to Raipur", "when": "2026-11-08 10:15"}, {"what": "Check-in closes", "when": "2026-11-09 09:15"}, {"what": "Web check-in opens", "when": "2026-11-08 11:35"}, {"what": "Flight 6E 537", "when": "2026-11-08 02:43"}]}"#
        #expect(Consolidator.checkedPlans(answer, page: pdf, now: today).map(\.summary) == ["Flight 6E 537 Bengaluru to Raipur"])
        // Already past.
        let later = today.addingTimeInterval(5 * 86400)
        #expect(Consolidator.checkedPlans(answer, page: pdf, now: later).isEmpty)
    }

    @Test func aBookingPageIsKnown() {
        let now = Date()
        func shot(_ title: String, _ url: String, _ text: String) -> Journal.Snapshot {
            Journal.Snapshot(id: 1, app: "Google Chrome", title: title, url: url, domain: URL(string: url)?.host ?? "",
                             text: text, first: now, last: now, seconds: 60, sightings: 1)
        }
        let me = ["Shubham Agrawal", "Shubham"]
        #expect(Consolidator.looksLikeBooking(shot("Itinerary", "https://www.goindigo.in/book/itinerary.html",
                                                   "Hello Shubham Agrawal | Your itinerary | Sun, 08 Nov 2026"), me: me))
        #expect(!Consolidator.looksLikeBooking(shot("Offers", "https://www.goindigo.in/offers",
                                                    "Book flights to Maldives | 10% off | 08 Nov"), me: me))
        #expect(!Consolidator.looksLikeBooking(shot("Feed | LinkedIn", "https://www.linkedin.com/feed/",
                                                    "Shubham, your booking for 08 Nov"), me: me))
    }

    @Test func aDeadlineIsNotTheFlight() {
        let journal = Journal(url: FileManager.default.temporaryDirectory.appendingPathComponent("journal-\(UUID().uuidString).sqlite"))
        let when = Date().addingTimeInterval(2 * 86400)
        journal.take([Journal.Promise(summary: "Flight 6E 537 Bengaluru to Raipur", due: when, kind: "plan"),
                      Journal.Promise(summary: "Check-in closes: Flight 6E 537 Bengaluru to Raipur", due: when.addingTimeInterval(-3600), kind: "plan")],
                     evidence: [1])
        #expect(journal.loops().count == 2)
        #expect(journal.loops().allSatisfy { $0.label == "Coming up" })
        // After it has flown, it's done.
        journal.take([], evidence: [], now: when.addingTimeInterval(2 * 3600))
        #expect(journal.loops().isEmpty)
    }
}
