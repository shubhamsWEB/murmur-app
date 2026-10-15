import XCTest
@testable import AgentKit

/// Opening a file by what was said. Every case is a real request from Murmur's log (English and Hinglish) and the
/// file names on the Mac it was said on. This has broken four times, each time in a different place; these keep the
/// fixes fixed. Run: swift test --filter AgentKitTests
final class OpeningFilesTests: XCTestCase {
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

    func testCardsAreFoundByName() {
        XCTAssertEqual(named("PAN card").first, "PanCard.pdf")
        XCTAssertEqual(named("my pan card").first, "PanCard.pdf")
        XCTAssertEqual(named("pen card").first, "PanCard.pdf", "how speech recognition hears “PAN card”")
        XCTAssertEqual(named("pancard").first, "PanCard.pdf")
        XCTAssertEqual(named("aadhaar card"), ["Aadhar.pdf"], "spelled differently in the name")
        XCTAssertEqual(named("Aadhaar"), ["Aadhar.pdf"])
        XCTAssertFalse(named("PAN card").contains("Company_Panel.pdf"))
    }

    func testPeopleAndResumes() {
        XCTAssertEqual(Set(named("Roma Patel CV")), ["Roma_Patel_CV.pdf", "Roma Patel CV.docx"])
        XCTAssertEqual(Set(named("roma patel resume cv")), ["Roma_Patel_CV.pdf", "Roma Patel CV.docx"])
        XCTAssertTrue(named("resume cv").contains("Resume_Shubham_Agrawal_.pdf"))
    }

    func testDescriptionsAreLeftToTheSearch() {
        // Nothing in a name says which one: the search (and the model) decide.
        XCTAssertEqual(named("pdf"), [])
        XCTAssertEqual(named("the PDF"), [])
        XCTAssertEqual(named("driving license"), [], "the license is a photo, IMG_5473.heic: only the search finds it")
        XCTAssertEqual(named("the clause about pets in the lease"), [])
        XCTAssertEqual(named("lease"), ["Lease 2025.pdf"])
    }

    func testTheModelsDescriptionIsNotReplaced() {
        // "Open my driving license and PAN card": the model asked for "PAN card", which is PanCard.pdf from before.
        // It used to be swapped for the whole sentence, which found a palmistry book.
        XCTAssertFalse(CommandAgent.namesAFile("PAN card"))
        XCTAssertFalse(CommandAgent.namesAFile("Roma Patel CV"))
        XCTAssertFalse(CommandAgent.namesAFile("Shubham Agrawal Aadhaar card"))
        XCTAssertTrue(CommandAgent.namesAFile("/Users/shubhamagr/Downloads/Aadhar.pdf"))
        XCTAssertTrue(CommandAgent.namesAFile("Aadhar.pdf"))
        XCTAssertTrue(CommandAgent.namesAFile("~/Downloads/Roma Patel CV.docx"))
    }

    func testTheFileFromBefore() {
        // Asked for by name: it's the file from before, and that's fine.
        XCTAssertTrue(CommandAgent.pointsBack("Open my driving license and PAN card.", to: "PanCard.pdf"))
        XCTAssertTrue(CommandAgent.pointsBack("Open my pan card.", to: "PanCard.pdf"))
        XCTAssertTrue(CommandAgent.pointsBack("Mera aadhaar card kholo.", to: "Aadhar.pdf"))
        XCTAssertTrue(CommandAgent.pointsBack("open it again", to: "Lease 2025.pdf"))
        XCTAssertTrue(CommandAgent.pointsBack("wahi PDF kholo", to: "Lease 2025.pdf"))
        // A new request: not the file from before, whatever the model hands back.
        XCTAssertFalse(CommandAgent.pointsBack("mujhe PDF kholkar do", to: "Aadhar.pdf"))
        XCTAssertFalse(CommandAgent.pointsBack("Open the PDF.", to: "Lease 2025.pdf"))
        XCTAssertFalse(CommandAgent.pointsBack("Mera driving license kholo.", to: "Aadhar.pdf"))
    }

    func testWhatASentenceAsksFor() {
        XCTAssertEqual(CommandAgent.fileWords("mujhe PDF kholkar do"), "pdf")
        XCTAssertEqual(CommandAgent.fileWords("Mera aadhaar card kholo."), "aadhaar card")
    }
}
