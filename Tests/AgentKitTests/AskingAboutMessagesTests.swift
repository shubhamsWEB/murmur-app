import Testing
@testable import AgentKit

/// Questions about your own chats and mail are for Murmur, even said with the cursor in a text field; the same words
/// said to someone stay text. Real requests from the log, and the ones that must stay dictation.
struct AskingAboutMessagesTests {
    func isQuestionForMurmur(_ said: String) -> Bool {
        let cleaned = QuickCommands.clean(said)
        return cleaned.range(of: IntentClassifier.aboutMyMessages, options: .regularExpression) != nil
            && cleaned.range(of: #"\b(you|your|u|tum|tumne|aap|aapne)\b"#, options: .regularExpression) == nil
    }

    @Test func questionsAboutYourMessages() {
        #expect(isQuestionForMurmur("What did I send to room on WhatsApp today?"))
        #expect(isQuestionForMurmur("What did I send roma in WhatsApp today?"))
        #expect(isQuestionForMurmur("Summarize my WhatsApp chat with Roma."))
        #expect(isQuestionForMurmur("Go through my unread emails and tell me what needs a reply."))
        #expect(isQuestionForMurmur("Roma ki WhatsApp chat padh ke batao."))
    }

    @Test func theSameWordsSaidToSomeone() {
        #expect(!isQuestionForMurmur("Did you see what I sent on WhatsApp?"))
        #expect(!isQuestionForMurmur("What did I tell you about the email?"))
        #expect(!isQuestionForMurmur("Read my message carefully."))
        #expect(!isQuestionForMurmur("Thanks, I got the mail."))
    }
}
