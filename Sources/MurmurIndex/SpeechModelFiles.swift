import Foundation

/// The speech-to-text models Murmur's Windows and Linux app dictates with, the Mac app's three (which it runs through
/// FluidAudio and WhisperKit instead). English is NVIDIA's Parakeet TDT 0.6B v2, the most accurate for English;
/// Multilingual is v3, 25 European languages: sherpa-onnx's int8 ONNX conversions, at pinned revisions. Hinglish is
/// Oriserve's Whisper-Hindi2Hinglish-Apex, converted to sherpa-onnx's Whisper format by the repository's Hinglish model
/// workflow (.github/workflows/hinglish-model.yml, scripts/hinglish/), from Oriserve's weights at a pinned revision,
/// and published as a release of Murmur's repository with a manifest of its files (sizes, SHA-256). The shell
/// downloads one with `murmur-engine download-speech-model` and runs it itself (sherpa-onnx, in shell/src-tauri).
public enum SpeechModelFiles: String, CaseIterable, Sendable {
    case english
    case hinglish
    case multilingual

    /// The release the Hinglish model's files and their manifest are in.
    public static let hinglishRelease = URL(string: "https://github.com/shubhamsWEB/murmur-app/releases/download/hinglish-apex-v1/")!

    /// Where the model's files are kept: Murmur's folder, Speech Models/<name>.
    public var folderName: String {
        switch self {
        case .english: return "parakeet-tdt-0.6b-v2-int8"
        case .hinglish: return "whisper-hinglish-apex-int8"
        case .multilingual: return "parakeet-tdt-0.6b-v3-int8"
        }
    }

    public var installed: URL {
        AppPaths.applicationSupport.appendingPathComponent("Speech Models").appendingPathComponent(folderName)
    }

    /// The pinned files (Hinglish's come from its release's manifest: `files(manifest:)`).
    public var files: [ModelFiles.File] {
        switch self {
        case .hinglish:
            return []
        case .english:
            let repository = "csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8"
            let revision = "1ab9323565ddb038682214b292f588070a538ce2"
            return [
                .init(name: "tokens.txt", bytes: 9_384,
                      sha256: "ec182b70dd42113aff6c5372c75cac58c952443eb22322f57bbd7f53977d497d",
                      repository: repository, revision: revision),
                .init(name: "decoder.int8.onnx", bytes: 7_257_753,
                      sha256: "b6bb64963457237b900e496ee9994b59294526439fbcc1fecf705b31a15c6b4e",
                      repository: repository, revision: revision),
                .init(name: "joiner.int8.onnx", bytes: 1_739_080,
                      sha256: "7946164367946e7f9f29a122407c3252b680dbae9a51343eb2488d057c3c43d2",
                      repository: repository, revision: revision),
                .init(name: "encoder.int8.onnx", bytes: 652_184_296,
                      sha256: "a32b12d17bbbc309d0686fbbcc2987b5e9b8333a7da83fa6b089f0a2acd651ab",
                      repository: repository, revision: revision),
            ]
        case .multilingual:
            let repository = "csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8"
            let revision = "2bda32ec70b097a55adaa07d9a7173915b43cc78"
            return [
                .init(name: "tokens.txt", bytes: 93_939,
                      sha256: "d58544679ea4bc6ac563d1f545eb7d474bd6cfa467f0a6e2c1dc1c7d37e3c35d",
                      repository: repository, revision: revision),
                .init(name: "decoder.int8.onnx", bytes: 11_845_275,
                      sha256: "179e50c43d1a9de79c8a24149a2f9bac6eb5981823f2a2ed88d655b24248db4e",
                      repository: repository, revision: revision),
                .init(name: "joiner.int8.onnx", bytes: 6_355_277,
                      sha256: "3164c13fc2821009440d20fcb5fdc78bff28b4db2f8d0f0b329101719c0948b3",
                      repository: repository, revision: revision),
                .init(name: "encoder.int8.onnx", bytes: 652_184_281,
                      sha256: "acfc2b4456377e15d04f0243af540b7fe7c992f8d898d751cf134c3a55fd2247",
                      repository: repository, revision: revision),
            ]
        }
    }

    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }

    /// The files not in `folder` yet (only verified files get their final name, so being there is enough).
    public func missing(in folder: URL) -> [ModelFiles.File] {
        Self.missing(files, in: folder)
    }

    public static func missing(_ files: [ModelFiles.File], in folder: URL) -> [ModelFiles.File] {
        files.filter { !FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.name).path) }
    }

    /// The Hinglish model's files from its release's manifest.json: {"files": [{"name", "bytes", "sha256"}, …]}, each
    /// downloaded from the release. Only the three files sherpa-onnx loads, with sane sizes, are taken.
    public static func hinglishFiles(manifest: Data) throws -> [ModelFiles.File] {
        struct Manifest: Decodable {
            struct Entry: Decodable { let name: String; let bytes: Int64; let sha256: String }
            let files: [Entry]
        }
        let entries = try JSONDecoder().decode(Manifest.self, from: manifest).files
        let wanted: Set = ["tokens.txt", "decoder.int8.onnx", "encoder.int8.onnx"]
        let files = entries.filter { wanted.contains($0.name) }.map { entry in
            ModelFiles.File(name: entry.name, bytes: entry.bytes, sha256: entry.sha256.lowercased(), repository: "",
                            revision: "", address: hinglishRelease.appendingPathComponent(entry.name))
        }
        guard Set(files.map(\.name)) == wanted,
              files.allSatisfy({ $0.bytes > 0 && $0.bytes < 2_000_000_000 && $0.sha256.count == 64 }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return files
    }
}
