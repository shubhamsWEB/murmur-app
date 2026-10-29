import Foundation
import Testing
@testable import MurmurIndex

/// What photo search finds, the new way against the old (`PhotoSearchScenarios`). Serialized: the search's switches
/// are shared.
@Suite(.serialized) struct PhotoSearchTests {
    typealias P = PhotoSearchScenarios

    /// "cat photo" with a photo of a cat that scores below the documents' level. Before, it was missed in a small
    /// library and came second or third in bigger ones. With what the photo shows as words (a Mac) it comes first;
    /// without (Windows, Linux) it's found in a small library too, and never ranks lower than it did.
    @Test(arguments: [(120, 8), (120, 30), (400, 200)])
    func thePhotoIsFound(docs: Int, photos: Int) throws {
        for labelled in [true, false] {
            let library = try P.library(docs: docs, photos: photos, labelled: labelled)
            let old = try P.rank(of: library, "cat photo", .old)
            let rank = try P.rank(of: library, "cat photo", .new)
            if photos < 20 { #expect(old == nil) }
            #expect((rank ?? 99) <= (old ?? 99))
            if labelled {
                #expect(rank == 1)
            } else {
                #expect((rank ?? 99) <= 5)
            }
        }
    }

    /// Documents' searches find the same, in the same order, with a few photos in the library or many.
    @Test func documentSearchesAreUnchanged() throws {
        for seed in 1...12 as ClosedRange<UInt64> {
            let library = try P.library(docs: 300, photos: seed % 2 == 0 ? 8 : 150, withCat: false, labelled: true,
                                        seed: seed)
            #expect(try P.search(library, "budget notes", .new) == P.search(library, "budget notes", .old))
        }
    }

    /// With no photo of a cat, "cat photo" rarely shows a photo at all: about one search in ten (the bar rises with the
    /// number of photos).
    @Test func noPhotoIsShownForWhatIsntThere() throws {
        var shown = 0, searches = 0
        for seed in 1...20 as ClosedRange<UInt64> {
            for photos in [8, 60, 400] {
                let library = try P.library(docs: 100, photos: photos, withCat: false, labelled: false, seed: seed)
                searches += 1
                if try P.search(library, "cat photo", .new).contains(where: { $0.contains("/photos/") }) { shown += 1 }
            }
        }
        #expect(Double(shown) / Double(searches) < 0.2)
    }

    /// A photo's labels don't push a document that answers the question off the top.
    @Test func labelsDontTakeOverDocuments() throws {
        let library = try P.library(docs: 120, photos: 30, withCat: false, labelled: true)
        #expect(try P.search(library, "beach travel notes", .new).first?.contains("/docs/") == true)
    }

    @Test func nearMissBarRisesWithTheLibrary() {
        #expect(abs(Searcher.nearMissBar(9) - 2.90) < 0.02)
        #expect(abs(Searcher.nearMissBar(61) - 3.07) < 0.02)
        #expect(abs(Searcher.nearMissBar(401) - 3.51) < 0.02)
        #expect(abs(Searcher.nearMissBar(2001) - 3.90) < 0.02)
    }

    @Test func photoWordsAreKeptOnlyWhenThereAreWords() {
        #expect(PhotoText.kept("e") == "")
        #expect(PhotoText.kept("STOP") == "")
        #expect(PhotoText.kept("Total due 1,240.00 Thank you") == "Total due 1,240.00 Thank you")
        #expect(PhotoText.labelText(["cat", "sports_car", "Cat"]) == "cat, sports car")
    }
}
