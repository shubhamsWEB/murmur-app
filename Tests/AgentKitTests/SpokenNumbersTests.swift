import Testing
@testable import AgentKit

/// Numbers said as words, written as digits where that's how they're written; ordinary words left alone.
struct SpokenNumbersTests {
    @Test func versionsAndDecimals() {
        #expect(SpokenNumbers.digits("complete all the tasks in the version one point three")
                == "complete all the tasks in the version 1.3")
        #expect(SpokenNumbers.digits("Version one point three.") == "Version 1.3.")
        #expect(SpokenNumbers.digits("upgrade to two point one point four today") == "upgrade to 2.1.4 today")
        #expect(SpokenNumbers.digits("it went up by zero point five") == "it went up by 0.5")
        #expect(SpokenNumbers.digits("ship version two next week") == "ship version 2 next week")
        #expect(SpokenNumbers.digits("Murmur one point nine point zero is out") == "Murmur 1.9.0 is out")
    }

    @Test func biggerNumbersAndYears() {
        #expect(SpokenNumbers.digits("we have twenty five people") == "we have 25 people")
        #expect(SpokenNumbers.digits("about three hundred and fifty users") == "about 350 users")
        #expect(SpokenNumbers.digits("in two thousand twenty six") == "in 2026")
        #expect(SpokenNumbers.digits("since nineteen ninety nine") == "since 1999")
        #expect(SpokenNumbers.digits("by twenty twenty seven") == "by 2027")
        #expect(SpokenNumbers.digits("it costs five lakh rupees") == "it costs ₹500000")
        #expect(SpokenNumbers.digits("ten people came") == "10 people came")
        #expect(SpokenNumbers.digits("twenty-five minutes") == "25 minutes")
    }

    @Test func unitsCurrencyAndTimes() {
        #expect(SpokenNumbers.digits("a ten percent discount") == "a 10% discount")
        #expect(SpokenNumbers.digits("growth of five percent, not more") == "growth of 5%, not more")
        #expect(SpokenNumbers.digits("it's fifty dollars") == "it's $50")
        #expect(SpokenNumbers.digits("meet at five pm") == "meet at 5 pm")
        #expect(SpokenNumbers.digits("sixteen gb of memory") == "16 GB of memory")
        #expect(SpokenNumbers.digits("open page three") == "open page 3")
    }

    @Test func wordsThatStayWords() {
        for text in ["I have two kids", "one of them said no", "no one came", "someone said it",
                     "the point is we ship", "that's a fine point", "one more thing", "do it once",
                     "kal file bhej dena", "Let's meet at 5, no, 6pm.", "a thousand thanks",
                     "one or two of us", "between three and four", ""] {
            #expect(SpokenNumbers.digits(text) == text, "\(text)")
        }
    }

    @Test func twoNumbersSideBySideStaySeparate() {
        // Not one number: each part on its own, the small ones left as words.
        #expect(SpokenNumbers.digits("fifty and sixty") == "50 and 60")
        #expect(SpokenNumbers.digits("five six seven") == "five six seven")
    }

    @Test func timesAndNames() {
        #expect(SpokenNumbers.digits("call me at eleven thirty") == "call me at 11:30")
        #expect(SpokenNumbers.digits("let's start by nine fifteen pm") == "let's start by 9:15 pm")
        #expect(SpokenNumbers.digits("eleven thirty is fine") == "eleven thirty is fine")
        #expect(SpokenNumbers.digits("Start with P two P one and then the rest") == "Start with P2 P1 and then the rest")
        #expect(SpokenNumbers.digits("call me on nine eight four five") == "call me on nine eight four five")
        #expect(SpokenNumbers.digits("four by four") == "four by four")
    }

    @Test func everythingForComparing() {
        #expect(SpokenNumbers.allDigits("I have two kids") == "I have 2 kids")
        #expect(SpokenNumbers.allDigits("version one point three") == "version 1.3")
    }

    @Test func spacingAndPunctuationAreKept() {
        #expect(SpokenNumbers.digits("Total: twenty five, then thirty.") == "Total: 25, then 30.")
        #expect(SpokenNumbers.digits("(version one point two)") == "(version 1.2)")
        #expect(SpokenNumbers.digits("line one\nversion two point zero\n") == "line one\nversion 2.0\n")
    }
}
