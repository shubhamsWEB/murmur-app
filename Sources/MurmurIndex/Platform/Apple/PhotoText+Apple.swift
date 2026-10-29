// What a photo shows and the words in it, with Apple Vision (on this Mac, nothing leaves it).
#if canImport(Vision)
import Foundation
import ImageIO
import Vision

extension PhotoText {
    static let readsLabels = true

    /// The most labels a photo keeps (Vision's are a hierarchy: "cat", "feline", "mammal", "animal").
    static let maxLabels = 12

    /// What the photo at `url` shows and the words in it. Read from a copy of at most 1,600 pixels (a 48 MP photo is
    /// never decoded whole), turned as it's shown.
    static func read(_ url: URL) -> Read {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 1600,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary)
        else { return Read() }
        let classify = VNClassifyImageRequest()
        let words = VNRecognizeTextRequest()
        words.recognitionLevel = .accurate
        words.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: image).perform([classify, words])
        // High precision only: a label is a promise that "cat" finds this photo (Vision's own advice for search:
        // at least 1% recall at 90% precision).
        let labels = (classify.results ?? [])
            .filter { $0.confidence > 0.1 && $0.hasMinimumRecall(0.01, forPrecision: 0.9) }
            .sorted { $0.confidence > $1.confidence }
            .prefix(maxLabels)
            .map(\.identifier)
        let text = (words.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        return Read(labels: Array(labels), text: kept(text))
    }
}
#endif
