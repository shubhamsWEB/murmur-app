import Foundation
import Testing
@testable import VoiceKit

/// The half second before the key (from the 9 Nov log: "Sudoku" heard as "Doku", "So all this"), and how much of
/// the original goes back under noise-reduced sound.
struct VoiceInputTests {
    @Test func preRollKeepsTheNewestSound() {
        var roll = PreRoll(capacity: 4)
        #expect(roll.contents().isEmpty)
        roll.append([1, 2])
        #expect(roll.contents() == [1, 2])
        roll.append([3, 4, 5])
        #expect(roll.contents() == [2, 3, 4, 5])
        roll.append([6, 7, 8, 9, 10, 11])
        #expect(roll.contents() == [8, 9, 10, 11])
        roll.clear()
        #expect(roll.contents().isEmpty)
        roll.resize(2)
        roll.append([1, 2, 3])
        #expect(roll.contents() == [2, 3])
    }

    @Test func aPreRollOfNothingKeepsNothing() {
        var roll = PreRoll(capacity: 0)
        roll.append([1, 2, 3])
        #expect(roll.contents().isEmpty)
    }

    /// Some of the original goes back under noise-reduced sound: more when the voice is clear of the noise.
    @Test func theOriginalIsMixedBackByHowClearTheVoiceIs() {
        #expect(AudioLevel.observationShare(speechOverNoiseDB: 0) == 0.10)
        #expect(AudioLevel.observationShare(speechOverNoiseDB: 10) == 0.25)
        #expect(AudioLevel.observationShare(speechOverNoiseDB: 40) == 0.25)
        let middle = AudioLevel.observationShare(speechOverNoiseDB: 6.5)
        #expect(middle > 0.10 && middle < 0.25)
    }

    // MARK: Vocabulary, decided by how sure Parakeet was

    @Test func piecesBecomeWordsAsSureAsTheirLeastSurePiece() {
        let heard = DictationVocabulary.words(fromPieces: [("▁Solve", 0.98), ("▁this", 0.97), ("▁Do", 0.45),
                                                           ("ku", 0.80), ("▁puzzle", 0.93), (".", 0.99)])
        #expect(heard.map(\.text) == ["Solve", "this", "Doku", "puzzle."])
        #expect(heard[2].confidence == 0.45)
        #expect(heard[3].confidence == 0.93)
        // A leading space marks a word too.
        #expect(DictationVocabulary.words(fromPieces: [(" Hi", 0.9), (" there", 0.8)]).map(\.text) == ["Hi", "there"])
        #expect(DictationVocabulary.words(fromPieces: []).isEmpty)
    }

    /// 10 Nov: the spotter swapped words Parakeet had heard right. A word it was sure of now stays.
    @Test func aWordParakeetWasSureOfIsNeverSwapped() {
        let sure: Float = 0.95
        let heard = ["So", "we", "need", "to", "fill", "the", "rest.", "Continue."].map {
            DictationVocabulary.HeardWord(text: $0, confidence: sure)
        }
        let swaps: [DictationVocabulary.Replacement] = [.init(original: "So we need to", replacement: "Claude"),
                                                        .init(original: "Fill the rest.", replacement: "Shubham"),
                                                        .init(original: "Continue.", replacement: "Sudoku")]
        #expect(DictationVocabulary.believable(swaps, heard: heard).isEmpty)
        // Even a close spelling: sure is sure.
        let cloud = [DictationVocabulary.HeardWord(text: "cloud", confidence: sure)]
        #expect(DictationVocabulary.believable([.init(original: "cloud", replacement: "Claude")], heard: cloud).isEmpty)
    }

    @Test func anUnsureNearMissIsSwapped() {
        let heard = [DictationVocabulary.HeardWord(text: "Solve", confidence: 0.97),
                     DictationVocabulary.HeardWord(text: "this", confidence: 0.96),
                     DictationVocabulary.HeardWord(text: "Doku", confidence: 0.41),
                     DictationVocabulary.HeardWord(text: "puzzle.", confidence: 0.93)]
        let swap = DictationVocabulary.Replacement(original: "Doku", replacement: "Sudoku")
        #expect(DictationVocabulary.believable([swap], heard: heard) == [swap])
        #expect(DictationVocabulary.apply([swap], to: "Solve this Doku puzzle.") == "Solve this Sudoku puzzle.")
        #expect(DictationVocabulary.unsure(heard) == "Doku 0.41")
    }

    @Test func anUnsureWordStillNeedsToSoundLikeTheListedOne() {
        let unsure: Float = 0.3
        let heard = ["domain", "Sudoku", "puzzle."].map { DictationVocabulary.HeardWord(text: $0, confidence: unsure) }
        // Not spelled alike, or not the same number of words: Parakeet's words stay.
        #expect(DictationVocabulary.believable([.init(original: "domain", replacement: "Claude")], heard: heard).isEmpty)
        #expect(DictationVocabulary.believable([.init(original: "Sudoku puzzle.", replacement: "Sudoku")],
                                               heard: heard).isEmpty)
        // Nothing to change, or not among the words heard.
        #expect(DictationVocabulary.believable([.init(original: "Sudoku", replacement: "Sudoku")], heard: heard).isEmpty)
        #expect(DictationVocabulary.believable([.init(original: "Arena", replacement: "Arena")], heard: heard).isEmpty)
        // Only the capitals: fine when unsure.
        let lower = [DictationVocabulary.HeardWord(text: "sudoku", confidence: unsure)]
        #expect(DictationVocabulary.believable([.init(original: "sudoku", replacement: "Sudoku")], heard: lower).count == 1)
    }

    @Test func theWindowsDistinctiveWordsAreListenedFor() {
        #expect(DictationVocabulary.terms(windowTitle: "Sudoku Arena - Google Chrome – Shubham", appName: "Google Chrome",
                                          userWords: []) == ["Sudoku", "Arena", "Shubham"])
        let words = DictationVocabulary.userWords(from: "Parakeet, FluidAudio\nCopico;  sudoku ")
        #expect(words == ["Parakeet", "FluidAudio", "Copico", "sudoku"])
        #expect(DictationVocabulary.terms(windowTitle: "Sudoku Arena", appName: nil, userWords: words)
                == ["Parakeet", "FluidAudio", "Copico", "sudoku", "Arena"])
        #expect(DictationVocabulary.terms(windowTitle: "NEW: How To Play The Best Free Games | Safari", appName: "Safari",
                                          userWords: []).isEmpty)
        #expect(DictationVocabulary.screenWords(in: "pull request · murmur-app · iPhone") == ["iPhone"])
        let many = (0..<100).map { "Word\($0)x" }
        #expect(DictationVocabulary.terms(windowTitle: nil, appName: nil, userWords: many).count == DictationVocabulary.maxTerms)
    }
}
