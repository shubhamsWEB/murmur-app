import Foundation

/// Words for a photo beyond its picture vector, for keyword search: what it shows ("cat, animal") and the words in it
/// (a receipt, a sign, a whiteboard). A photo used to have only its vector and its name, and "IMG_4821.jpeg" or
/// "WhatsApp Image…" says nothing: "cat photo" had to win on meaning alone. On macOS both come from Apple Vision;
/// elsewhere the words in it come from the app's OCR helper when it has one (Windows' own OCR, `OCRHelper`) and there
/// are no labels. Labels and text never get vectors: meaning stays the picture's own, as screenshots' OCR does (a
/// vector of the words made screenshots outrank better matches, 2026-10-08).
enum PhotoText {
    struct Read: Sendable {
        var labels: [String] = []
        var text = ""
    }

    /// Bumped when what's read changes: photos read by an older version are read again (`Indexer.readPhotos`).
    static let version = 1

    /// Text in a photo counts once it has this many words: a stray letter on a T-shirt or a logo doesn't.
    static let minWords = 3

    /// The words in a photo worth keeping for keyword search, or "" (`minWords`).
    static func kept(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
            .filter { $0.count >= 2 && $0.contains(where: \.isLetter) }
        return words.count >= minWords ? trimmed : ""
    }

    /// Labels as they're stored and shown: "sports_car" → "sports car", each once, in the order given.
    static func labelText(_ labels: [String]) -> String {
        var seen = Set<String>()
        return labels.map { $0.replacingOccurrences(of: "_", with: " ").lowercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: ", ")
    }

    /// Whether anything can be read here: photos get nothing new where neither labels nor text can be read.
    static var isAvailable: Bool { readsLabels || OCRHelper.command != nil }
}

/// The app's OCR helper, for systems without Apple Vision: a program that takes a picture's path and prints its text.
/// The Windows app passes its own (Murmur.exe --ocr, which uses Windows.Media.Ocr) in `MURMUR_OCR`.
enum OCRHelper {
    static var command: String? {
        guard let path = ProcessInfo.processInfo.environment["MURMUR_OCR"], !path.isEmpty,
              FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }

    /// The text in the picture at `path` ("" when there's none, the helper failed or took over `timeout` seconds). Its
    /// output goes to a file, not a pipe, so a long text can't stall it.
    static func text(ofImageAt path: String, timeout: TimeInterval = 20) -> String {
        guard let command else { return "" }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-ocr-\(UUID().uuidString).txt")
        guard FileManager.default.createFile(atPath: out.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: out) else { return "" }
        defer { try? FileManager.default.removeItem(at: out) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = ["--ocr", path]
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { try? handle.close(); return "" }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning {
            process.terminate()
            try? handle.close()
            return ""
        }
        try? handle.close()
        guard process.terminationStatus == 0, let data = try? Data(contentsOf: out) else { return "" }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
