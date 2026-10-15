import XCTest
@testable import AgentKit

/// Questions about your own chats and mail are for Murmur, even said with the cursor in a text field; the same words
/// said to someone stay text. Real requests from the log, and the ones that must stay dictation.
final class AskingAboutMessagesTests: XCTestCase {
    func isQuestionForMurmur(_ said: String) -> Bool {
        let cleaned = QuickCommands.clean(said)
        return cleaned.range(of: IntentClassifier.aboutMyMessages, options: .regularExpression) != nil
            && cleaned.range(of: #"\b(you|your|u|tum|tumne|aap|aapne)\b"#, options: .regularExpression) == nil
    }

    func testQuestionsAboutYourMessages() {
        XCTAssertTrue(isQuestionForMurmur("What did I send to room on WhatsApp today?"))
        XCTAssertTrue(isQuestionForMurmur("What did I send roma in WhatsApp today?"))
        XCTAssertTrue(isQuestionForMurmur("Summarize my WhatsApp chat with Roma."))
        XCTAssertTrue(isQuestionForMurmur("Go through my unread emails and tell me what needs a reply."))
        XCTAssertTrue(isQuestionForMurmur("Roma ki WhatsApp chat padh ke batao."))
    }

    func testTheSameWordsSaidToSomeone() {
        XCTAssertFalse(isQuestionForMurmur("Did you see what I sent on WhatsApp?"))
        XCTAssertFalse(isQuestionForMurmur("What did I tell you about the email?"))
        XCTAssertFalse(isQuestionForMurmur("Read my message carefully."))
        XCTAssertFalse(isQuestionForMurmur("Thanks, I got the mail."))
    }
}
