import Testing
@testable import AgentKit

/// Fitting dictation to the sentence it lands in: spacing, the first letter's case and the final full stop only.
struct TextFitTests {
    let words: Set<String> = ["tomorrow", "meeting", "works", "the", "we", "a", "and", "sounds", "good", "thanks"]

    func fit(_ t: String, _ b: String, _ a: String) -> String {
        TextFit.fit(t, before: b, after: a, isWord: { words.contains($0) })
    }

    @Test func emptyField() { #expect(fit("Tomorrow works.", "", "") == "Tomorrow works.") }
    @Test func afterSentence() { #expect(fit("tomorrow works.", "ok. ", "") == "Tomorrow works.") }
    @Test func afterSentenceNoSpace() { #expect(fit("Tomorrow works.", "ok.", "") == " Tomorrow works.") }
    @Test func midSentence() { #expect(fit("Tomorrow works.", "I think ", "") == "tomorrow works.") }
    @Test func midSentenceNoSpace() { #expect(fit("Tomorrow works.", "I think", "") == " tomorrow works.") }
    @Test func keepsNames() { #expect(fit("Monday works.", "how about ", "") == "Monday works.") }
    @Test func keepsI() { #expect(fit("I think so.", "and ", "") == "I think so.") }
    @Test func keepsIm() { #expect(fit("I'm in.", "and ", "") == "I'm in.") }
    @Test func keepsAcronym() { #expect(fit("API calls.", "the ", "") == "API calls.") }
    @Test func lowerA() { #expect(fit("A meeting.", "we need ", "") == "a meeting.") }
    @Test func beforeWordDropsStop() { #expect(fit("The meeting.", "", "and more") == "The meeting ") }
    @Test func beforeSpaceWordDropsStop() { #expect(fit("The meeting.", "", " and more") == "The meeting") }
    @Test func beforeCapitalKeepsStop() { #expect(fit("Sounds good.", "", " Thanks") == "Sounds good.") }
    @Test func beforeComma() { #expect(fit("Sounds good.", "Well ", ", thanks") == "sounds good") }
    @Test func afterComma() { #expect(fit("Sounds good.", "Well,", "") == " sounds good.") }
    @Test func newline() { #expect(fit("tomorrow.", "Hi\n", "") == "Tomorrow.") }
    @Test func openParen() { #expect(fit("Sounds good.", "(", ")") == "Sounds good.") }
    @Test func ellipsisKept() { #expect(fit("And then...", "well ", "so") == "and then... ") }
    @Test func hinglish() { #expect(fit("main kal aaunga.", "", "") == "Main kal aaunga.") }
    @Test func whitespaceOnly() { #expect(fit("  ", "x", "") == "  ") }
}
