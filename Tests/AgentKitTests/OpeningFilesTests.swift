import Testing
@testable import AgentKit

/// Opening a file by what was said. Every case is a real request from Murmur's log (English and Hinglish) and the
/// file names on the Mac it was said on. This has broken four times, each time in a different place; these keep the
/// fixes fixed. Run: swift test --filter AgentKitTests
struct OpeningFilesTests {
    let files = [
        "PanCard.pdf", "Aadhar.pdf", "IMG_5473.heic", "llm-full.txt", "Frido-Product-Handover.pdf",
        "2015.126740.The-Study-Of-Palmistry-For-Professional-Purposes_text.pdf", "Resume_Shubham_Agrawal_.pdf",
        "Roma_Patel_CV.pdf", "Roma Patel CV.docx", "Lease 2025.pdf", "Company_Panel.pdf",
        "Signed_S26_Form_50_S26050O8C0212251200112_690c210a-00f6-4da6-a69b-54f025a3fd9d_Form8S260.pdf",
    ]

    /// The files whose names answer `query`, best first.
    func named(_ query: String) -> [String] {
        files.compactMap { name in FileNameMatch.score(name: name, for: query).map { (name, $0) } }
            .sorted { $0.1 > $1.1 }.map(\.0)
    }

    @Test func cardsAreFoundByName() {
        #expect(named("PAN card").first == "PanCard.pdf")
        #expect(named("my pan card").first == "PanCard.pdf")
        #expect(named("pen card").first == "PanCard.pdf", "how speech recognition hears “PAN card”")
        #expect(named("pancard").first == "PanCard.pdf")
        #expect(named("aadhaar card") == ["Aadhar.pdf"], "spelled differently in the name")
        #expect(named("Aadhaar") == ["Aadhar.pdf"])
        #expect(!named("PAN card").contains("Company_Panel.pdf"))
    }

    @Test func peopleAndResumes() {
        #expect(Set(named("Roma Patel CV")) == ["Roma_Patel_CV.pdf", "Roma Patel CV.docx"])
        #expect(Set(named("roma patel resume cv")) == ["Roma_Patel_CV.pdf", "Roma Patel CV.docx"])
        #expect(named("resume cv").contains("Resume_Shubham_Agrawal_.pdf"))
    }

    @Test func descriptionsAreLeftToTheSearch() {
        // Nothing in a name says which one: the search (and the model) decide.
        #expect(named("pdf") == [])
        #expect(named("the PDF") == [])
        #expect(named("driving license") == [], "the license is a photo, IMG_5473.heic: only the search finds it")
        #expect(named("the clause about pets in the lease") == [])
        #expect(named("lease") == ["Lease 2025.pdf"])
    }

    @Test func theModelsDescriptionIsNotReplaced() {
        // "Open my driving license and PAN card": the model asked for "PAN card", which is PanCard.pdf from before.
        // It used to be swapped for the whole sentence, which found a palmistry book.
        #expect(!CommandAgent.namesAFile("PAN card"))
        #expect(!CommandAgent.namesAFile("Roma Patel CV"))
        #expect(!CommandAgent.namesAFile("Shubham Agrawal Aadhaar card"))
        #expect(CommandAgent.namesAFile("/Users/shubhamagr/Downloads/Aadhar.pdf"))
        #expect(CommandAgent.namesAFile("Aadhar.pdf"))
        #expect(CommandAgent.namesAFile("~/Downloads/Roma Patel CV.docx"))
    }

    @Test func theFileFromBefore() {
        // Asked for by name: it's the file from before, and that's fine.
        #expect(CommandAgent.pointsBack("Open my driving license and PAN card.", to: "PanCard.pdf"))
        #expect(CommandAgent.pointsBack("Open my pan card.", to: "PanCard.pdf"))
        #expect(CommandAgent.pointsBack("Mera aadhaar card kholo.", to: "Aadhar.pdf"))
        #expect(CommandAgent.pointsBack("open it again", to: "Lease 2025.pdf"))
        #expect(CommandAgent.pointsBack("wahi PDF kholo", to: "Lease 2025.pdf"))
        // A new request: not the file from before, whatever the model hands back.
        #expect(!CommandAgent.pointsBack("mujhe PDF kholkar do", to: "Aadhar.pdf"))
        #expect(!CommandAgent.pointsBack("Open the PDF.", to: "Lease 2025.pdf"))
        #expect(!CommandAgent.pointsBack("Mera driving license kholo.", to: "Aadhar.pdf"))
    }

    @Test func whatASentenceAsksFor() {
        #expect(CommandAgent.fileWords("mujhe PDF kholkar do") == "pdf")
        #expect(CommandAgent.fileWords("Mera aadhaar card kholo.") == "aadhaar card")
    }
}
