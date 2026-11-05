import Foundation

/// The model Murmur reads with (notes, email, connected apps, what you worked on) when it doesn't use Ollama: Qwen3, in
/// Qwen's own GGUF conversions at pinned revisions (Apache-2.0), run by llama.cpp in `murmur-engine reader-service`.
/// The 4B model on a Mac with more than 8 GB of memory; the 1.7B one otherwise.
public enum ReaderModelFiles {
    public static let large = ModelFiles.File(
        name: "Qwen3-4B-Q4_K_M.gguf", bytes: 2_497_280_256,
        sha256: "7485fe6f11af29433bc51cab58009521f205840f5b4ae3a32fa7f92e8534fdf5",
        repository: "Qwen/Qwen3-4B-GGUF", revision: "bc640142c66e1fdd12af0bd68f40445458f3869b")
    public static let small = ModelFiles.File(
        name: "Qwen3-1.7B-Q8_0.gguf", bytes: 1_834_426_016,
        sha256: "061b54daade076b5d3362dac252678d17da8c68f07560be70818cace6590cb1a",
        repository: "Qwen/Qwen3-1.7B-GGUF", revision: "90862c4b9d2787eaed51d12237eafdfe7c5f6077")

    /// The one for a machine with this much memory.
    public static func chosen(memory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> ModelFiles.File {
        memory > 9 << 30 ? large : small
    }

    /// Where it's kept: with the search model (Application Support/Murmur/Models).
    public static var folder: URL { ModelFiles.installed }

    /// The downloaded model to read with, the chosen one first. Only verified files get their final name.
    public static func installed(memory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> URL? {
        let preferred = chosen(memory: memory)
        for file in [preferred, preferred == large ? small : large] {
            let url = folder.appendingPathComponent(file.name)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// The socket the reader service listens on (one for the app and its helpers, so the model is loaded once).
    public static var socket: URL { AppPaths.applicationSupport.appendingPathComponent("reader.sock") }
}
