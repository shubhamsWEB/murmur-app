import Foundation

/// The speech-to-text models Murmur's Windows and Linux app dictates with: NVIDIA's Parakeet TDT 0.6B, as sherpa-onnx's
/// int8 ONNX conversion, at pinned revisions (the Mac app runs Parakeet on the Neural Engine through FluidAudio
/// instead). English is v2, the most accurate for English; Multilingual is v3, 25 European languages. The shell
/// downloads one with `murmur-engine download-speech-model` and runs it itself (sherpa-onnx, in shell/src-tauri).
public enum SpeechModelFiles: String, CaseIterable, Sendable {
    case english
    case multilingual

    /// Where the model's files are kept: Murmur's folder, Speech Models/<name>.
    public var folderName: String {
        switch self {
        case .english: return "parakeet-tdt-0.6b-v2-int8"
        case .multilingual: return "parakeet-tdt-0.6b-v3-int8"
        }
    }

    public var installed: URL {
        AppPaths.applicationSupport.appendingPathComponent("Speech Models").appendingPathComponent(folderName)
    }

    public var files: [ModelFiles.File] {
        switch self {
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
        files.filter { !FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.name).path) }
    }
}
